// Every stored health metric for the app: an overview of latest-vs-usual, and one metric's history with its usual band.
import { BY_KEY } from "./catalog.js";
import { all } from "./db.js";
import { freshnessBlock, latestDays } from "./health.js";
import { ApiError } from "./http.js";
import { baseline, compare, daily, decimals, heartRateBand, round } from "./stats.js";
import { addDays, today } from "./time.js";

const GROUPS: { name: string; keys: string[] }[] = [
  { name: "Heart", keys: ["resting_hr", "hrv", "heart_rate", "walking_hr", "vo2max"] },
  { name: "Sleep", keys: ["sleep_h", "deep_h", "rem_h", "respiratory_rate", "spo2", "wrist_temp"] },
  { name: "Activity", keys: ["steps", "active_kcal", "exercise_min", "stand_hours", "distance_km", "flights", "daylight_min", "resting_kcal"] },
  { name: "Body", keys: ["weight_kg", "body_fat_pct"] },
];
const NAMES: Record<string, string> = {
  resting_hr: "Resting heart rate", hrv: "HRV", heart_rate: "Heart rate", walking_hr: "Walking heart rate", vo2max: "VO₂ max",
  sleep_h: "Time asleep", deep_h: "Deep sleep", rem_h: "REM sleep", respiratory_rate: "Breathing rate", spo2: "Blood oxygen", wrist_temp: "Wrist temperature",
  steps: "Steps", active_kcal: "Active energy", exercise_min: "Exercise", stand_hours: "Stand hours", distance_km: "Distance", flights: "Flights climbed",
  daylight_min: "Time in daylight", resting_kcal: "Resting energy", weight_kg: "Weight", body_fat_pct: "Body fat",
};
// The overview's look-back: a metric with nothing in this window shows as missing rather than as a stale number.
const LATEST_WITHIN = 14;
const known = (k: string) => BY_KEY.has(k) && k !== "bedtime";
const name = (k: string) => NAMES[k] ?? BY_KEY.get(k)?.label ?? k;
const unit = (k: string) => BY_KEY.get(k)?.unit ?? all<{ unit: string }>("SELECT unit FROM metric_days WHERE metric=? LIMIT 1", k)[0]?.unit ?? "";

/** `/v2/metrics`: two indexed reads per metric (14-day window + 60-day baseline), ~25 metrics, once per request. */
export function metricsOverview(day: string, at = Date.now()) {
  const extra = Object.keys(latestDays()).filter((k) => !BY_KEY.has(k));
  const groups = [...GROUPS, ...(extra.length ? [{ name: "Other", keys: extra }] : [])];
  const from = addDays(day, -(LATEST_WITHIN - 1));
  return {
    day,
    groups: groups.map((g) => ({ name: g.name, metrics: g.keys.map((key) => {
      const vals = daily(key, from, day), last = [...vals.keys()].sort().at(-1);
      const spark = Array.from({ length: LATEST_WITHIN }, (_, i) => vals.get(addDays(from, i)) ?? null).map((v) => (v === null ? null : round(v, decimals(key))));
      const base = { key, name: name(key), unit: unit(key), better: BY_KEY.get(key)?.polarity ?? "neutral", spark };
      if (!last) return { ...base, day: null, value: null, usual: null, usual_range: null, flag: null, reading: null };
      const c = compare(key, last, vals.get(last)!);
      return { ...base, day: last, value: c.value, usual: c.usual, usual_range: c.usual_range ?? null, flag: c.flag ?? null, reading: c.reading ?? null };
    }) })),
    freshness: freshnessBlock(at),
  };
}

export const RANGES = [7, 30, 90, 365] as const;

/** `/v2/metrics/:key`: daily points up to 90 days, weekly averages beyond; the band is today's usual range (median, 10th–90th). */
export function metricHistory(key: string, days: number, end: string, at = Date.now()) {
  if (!known(key) && (BY_KEY.has(key) || !(key in latestDays()))) throw new ApiError(404, `No metric ${key}`, "not_found");
  if (!(RANGES as readonly number[]).includes(days)) throw new ApiError(400, `days must be one of ${RANGES.join(", ")}`, "bad_request");
  const from = addDays(end, -(days - 1)), d = decimals(key);
  const vals = daily(key, from, end), prev = daily(key, addDays(from, -days), addDays(from, -1));
  const xs = [...vals.values()], px = [...prev.values()];
  const mean = (a: number[]) => (a.length ? a.reduce((t, v) => t + v, 0) / a.length : null);
  const weekly = days > 90;
  const points = weekly ? weeks(vals, from, end, d) : [...vals].sort(([a], [b]) => a.localeCompare(b)).map(([day, v]) => ({ day, value: round(v, d) }));
  const b = baseline(key, addDays(end, 1)), avg = mean(xs), pavg = mean(px);
  const t = today(at);
  return {
    key, name: name(key), unit: unit(key), better: BY_KEY.get(key)?.polarity ?? "neutral", days, from, to: end,
    every: weekly ? "week" : "day", prev_end: addDays(from, -1), next_end: end >= t ? null : addDays(end, days) > t ? t : addDays(end, days),
    points,
    ...(key === "heart_rate" && !weekly && { band: [...heartRateBand(from, end)].sort(([a], [x]) => a.localeCompare(x))
      .map(([day, r]) => ({ day, lo: r.min === null ? null : Math.round(r.min), hi: r.max === null ? null : Math.round(r.max) })) }),
    days_with_data: xs.length,
    average: avg === null ? null : round(avg, d), min: xs.length ? round(Math.min(...xs), d) : null, max: xs.length ? round(Math.max(...xs), d) : null,
    previous_average: pavg === null ? null : round(pavg, d),
    usual: b.raw ? { value: round(b.raw.usual, d), low: round(b.raw.low, d), high: round(b.raw.high, d), days: b.days } : null,
    freshness: freshnessBlock(at),
  };
}

/** Monday-start weeks inside the range, keyed by the week's first day. */
function weeks(vals: Map<string, number>, from: string, to: string, d: number) {
  const out: { day: string; value: number }[] = [];
  const dow = (new Date(`${from}T00:00:00Z`).getUTCDay() + 6) % 7;
  for (let w = addDays(from, -dow); w <= to; w = addDays(w, 7)) {
    const xs = Array.from({ length: 7 }, (_, i) => vals.get(addDays(w, i))).filter((v): v is number => v !== undefined);
    if (xs.length) out.push({ day: w, value: round(xs.reduce((t, v) => t + v, 0) / xs.length, d) });
  }
  return out;
}
