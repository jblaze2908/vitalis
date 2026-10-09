// Reads over Apple Health data: freshness, the morning brief, sleep and metric series. Every number an agent sees comes
// with the owner's own usual value and the arithmetic already done, so it can be quoted, not recomputed.
import { BY_KEY, METRICS, SLEEP_METRICS } from "./catalog.js";
import { httpErr } from "./config.js";
import { all, one } from "./db.js";
import { BASELINE_DAYS, baseline, compare, daily, decimals, heartRateBand, hm, nights, round, type Compared } from "./stats.js";
import { addDays, clock, daysBetween, eveningMinutes, fromEveningMinutes, isoAt, ownerOffsetMin, today } from "./time.js";
import { daysSinceTrained, lastTraining } from "./training.js";

export const NO_ROW = "A day with no value means nothing reached Vitalis for it (phone locked, sync not run yet), not zero.";

export function latestDays() {
  const out: Record<string, string> = {};
  for (const r of all<{ metric: string; d: string }>("SELECT metric, MAX(day) d FROM metric_days GROUP BY metric")) out[r.metric] = r.d;
  const s = one<{ d: string | null }>("SELECT MAX(day) d FROM sleep_nights")?.d;
  if (s) for (const k of SLEEP_METRICS) out[k.key] = s;
  return out;
}

const lastPush = () => one<{ received_at: number; automation: string | null; counts: string | null; warnings: string | null; error: string | null }>(
  "SELECT received_at,automation,counts,warnings,error FROM payloads ORDER BY id DESC LIMIT 1");

/** The short freshness block every read carries. */
export function freshFor(keys: string[]) {
  const p = lastPush(), latest = latestDays();
  return { last_sync: p ? isoAt(p.received_at, ownerOffsetMin(p.received_at)) : null,
    latest_day: Object.fromEntries(keys.map((k) => [k, latest[k] ?? null])), today: today() };
}

export function freshness() {
  const p = lastPush(), since = Date.now() - 7 * 86_400_000;
  const pushes = all<{ received_at: number; automation: string | null; counts: string | null; warnings: string | null; error: string | null }>(
    "SELECT received_at,automation,counts,warnings,error FROM payloads WHERE received_at >= ? ORDER BY id DESC", since);
  const problems = pushes.flatMap((x) => [...(x.error ? [x.error] : []), ...(JSON.parse(x.warnings ?? "[]") as string[])]);
  const session = one<{ s: number; off: number }>("SELECT started_at s, tz_offset_min off FROM sessions WHERE deleted_at IS NULL ORDER BY started_at DESC LIMIT 1");
  const known = new Set(METRICS.map((m) => m.key));
  const latest = latestDays();
  return {
    today: today(),
    last_sync: p ? { at: isoAt(p.received_at, ownerOffsetMin(p.received_at)), automation: p.automation, counts: JSON.parse(p.counts ?? "null"), parse_error: p.error } : null,
    syncs_last_7_days: pushes.length,
    sync_days_last_7: [...new Set(pushes.map((x) => isoAt(x.received_at, ownerOffsetMin(x.received_at)).slice(0, 10)))].sort(),
    problems_last_7_days: [...new Set(problems)].slice(0, 10),
    latest_day: latest,
    latest_strength_session: session ? isoAt(session.s, session.off) : null,
    latest_watch_workout: one<{ d: string | null }>("SELECT MAX(day) d FROM hk_workouts")?.d ?? null,
    other_metrics_stored: Object.keys(latest).filter((k) => !known.has(k) && !BY_KEY.has(k)),
    note: NO_ROW,
  };
}

function valueOn(key: string, day: string) {
  return daily(key, day, day).get(day) ?? null;
}
/** The day's value, or the most recent one in the 2 days before, saying which day it came from. */
function recent(key: string, day: string, back = 2): (Compared & { day: string }) | null {
  for (let i = 0; i <= back; i++) {
    const d = addDays(day, -i), v = valueOn(key, d);
    if (v !== null) return { day: d, ...compare(key, d, v) };
  }
  return null;
}

export function brief(dayArg?: string) {
  const day = dayArg ?? today();
  const night = nights(day, day)[0] ?? null;
  const sleep = night ? {
    night_ending: day, asleep: hm(night.asleep_h), ...compareAs("sleep_h", day, night.asleep_h),
    fell_asleep: clock(night.sleep_start), fell_asleep_vs_usual: night.sleep_start ? compare("bedtime", day, eveningMinutes(night.sleep_start)) : null,
    woke: clock(night.sleep_end), stages: { deep: night.deep_h != null ? hm(night.deep_h) : null, rem: night.rem_h != null ? hm(night.rem_h) : null,
      core: night.core_h != null ? hm(night.core_h) : null, awake: night.awake_h != null ? hm(night.awake_h) : null },
  } : { night_ending: day, missing: true, latest_night: one<{ d: string | null }>("SELECT MAX(day) d FROM sleep_nights")?.d ?? null };
  const recovery = { resting_hr: recent("resting_hr", day), hrv: recent("hrv", day), respiratory_rate: recent("respiratory_rate", day), wrist_temp: recent("wrist_temp", day) };
  const yesterday = addDays(day, -1);
  const activity = { day: yesterday, steps: recent("steps", yesterday, 0), active_kcal_estimate: recent("active_kcal", yesterday, 0), exercise_min: recent("exercise_min", yesterday, 0) };
  const body = weight(day);
  const since = daysSinceTrained(day);
  const training = { ...lastTraining(day), not_trained_7_days: Object.entries(since).filter(([, d]) => d === null || d >= 7).map(([m, d]) => (d === null ? `${m} (never logged)` : `${m} (${d} days)`)) };
  const verdict = judge(night ? (sleep as ReturnType<typeof compareAs>) : null, recovery.resting_hr, recovery.hrv, day);
  return { day, verdict, summary: summarize(day, sleep, recovery, body, training, verdict), sleep, recovery, activity, body, training,
    freshness: freshFor(["sleep_h", "resting_hr", "hrv", "weight_kg", "steps"]) };
}

const compareAs = (key: string, day: string, v: number) => { const c = compare(key, day, v); const { value: _v, unit: _u, ...rest } = c; return rest; };

function judge(sleep: { flag?: string; reading?: string; usual: unknown; delta?: number } | null, rhr: Compared | null, hrv: Compared | null, day: string) {
  const parts: [string, { reading?: string; flag?: string } | null][] = [["sleep", sleep], ["resting heart rate", rhr], ["HRV", hrv]];
  const have = parts.filter(([, c]) => c);
  const worse = have.filter(([, c]) => c!.reading === "worse").map(([n]) => n);
  const better = have.filter(([, c]) => c!.reading === "better").map(([n]) => n);
  const rule = "Rule: compare last night's sleep, resting heart rate and HRV with the 30-day usual range (10th–90th percentile). Two or more worse: easy. One worse: as planned, no records. Two or more better: good. Otherwise: normal.";
  if (!have.length) return { call: "unknown", reason: "No sleep, resting heart rate or HRV for this day yet.", worse, better, rule };
  // Judge only once some signal present today has a usual range to be judged against.
  const keyOf: Record<string, string> = { sleep: "sleep_h", "resting heart rate": "resting_hr", HRV: "hrv" };
  const nb = Math.max(...have.map(([n]) => baseline(keyOf[n], day).days));
  if (nb < 7) return { call: "unknown", reason: `Only ${nb} days of history before ${day}; a usual range needs 7.`, worse, better, rule };
  if (worse.length >= 2) return { call: "easy", reason: `${worse.join(" and ")} are outside your usual range on the bad side.`, worse, better, rule };
  if (worse.length === 1) return { call: "as_planned_no_records", reason: `${worse[0]} is off your usual; the rest is normal.`, worse, better, rule };
  if (better.length >= 2) return { call: "good", reason: `${better.join(" and ")} are better than usual.`, worse, better, rule };
  return { call: "normal", reason: "Within your usual range.", worse, better, rule };
}

function weight(day: string) {
  const vals = daily("weight_kg", addDays(day, -13), day);
  const last = [...vals].sort(([a], [b]) => b.localeCompare(a))[0];
  if (!last) return { weight_kg: null, note: "No weight logged in the last 14 days." };
  const avg = (from: string, to: string) => { const xs = [...vals].filter(([d]) => d >= from && d <= to).map(([, v]) => v); return xs.length ? { kg: round(xs.reduce((a, b) => a + b, 0) / xs.length, 1), entries: xs.length } : null; };
  const thisWeek = avg(addDays(day, -6), day), lastWeek = avg(addDays(day, -13), addDays(day, -7));
  return { weight_kg: round(last[1], 1), logged_on: last[0], logged_today: last[0] === day, avg_last_7_days: thisWeek, avg_previous_7_days: lastWeek,
    change_kg: thisWeek && lastWeek ? round(thisWeek.kg - lastWeek.kg, 1) : null };
}

function summarize(day: string, sleep: Record<string, unknown>, rec: Record<string, Compared | null>, body: ReturnType<typeof weight>,
  training: ReturnType<typeof lastTraining>, verdict: ReturnType<typeof judge>) {
  const s: string[] = [];
  const usual = (u: unknown) => (u === null || u === undefined ? "" : ` (usual ${u})`);
  if (sleep.missing) s.push(`No sleep recorded for the night ending ${day}${sleep.latest_night ? `; latest is ${sleep.latest_night}` : ""}.`);
  else {
    const fell = sleep.fell_asleep_vs_usual as Compared | null;
    s.push(`Slept ${sleep.asleep}${usual(typeof sleep.usual === "number" ? hm(sleep.usual) : sleep.usual)}, asleep ${sleep.fell_asleep}${usual(fell?.usual)}, up ${sleep.woke}.`);
  }
  const r = [rec.resting_hr && `resting heart rate ${rec.resting_hr.value}${usual(rec.resting_hr.usual)}`, rec.hrv && `HRV ${rec.hrv.value} ms${usual(rec.hrv.usual)}`].filter(Boolean);
  if (r.length) s.push(`${r.join(", ")}.`.replace(/^./, (c) => c.toUpperCase()));
  s.push(`Call: ${verdict.call.replace(/_/g, " ")}. ${verdict.reason}`);
  if (body.weight_kg !== null) s.push(`Weight ${body.weight_kg} kg${body.logged_today ? " today" : ` on ${body.logged_on}`}${body.change_kg !== null && body.change_kg !== undefined ? `, ${body.change_kg >= 0 ? "+" : ""}${body.change_kg} kg week on week` : ""}.`);
  const st = training.last_strength_session;
  s.push(st ? `Last strength session ${st.days_ago === 0 ? "today" : `${st.days_ago} days ago`}${st.title ? ` (${st.title})` : ""}.` : "No strength sessions logged yet.");
  return s.join(" ");
}

const MAX_RANGE = 366;
function range(from: string, to: string) {
  if (from > to) throw httpErr(400, "from is after to");
  if (daysBetween(from, to) > MAX_RANGE) throw httpErr(400, `Ask for at most ${MAX_RANGE} days at a time`);
}

export function getSleep(from: string, to: string) {
  range(from, to);
  const ns = nights(from, to);
  const bSleep = baseline("sleep_h", from), bBed = baseline("bedtime", from);
  const flag = (v: number, b: typeof bSleep) => (b.usual === null || !("raw" in b) || !b.raw ? undefined : v < b.raw.low ? "low" : v > b.raw.high ? "high" : undefined);
  const list = ns.map((n) => ({ night_ending: n.day, asleep: hm(n.asleep_h), asleep_h: round(n.asleep_h, 2), fell_asleep: clock(n.sleep_start), woke: clock(n.sleep_end),
    deep: n.deep_h != null ? hm(n.deep_h) : null, rem: n.rem_h != null ? hm(n.rem_h) : null, awake: n.awake_h != null ? hm(n.awake_h) : null,
    ...(flag(n.asleep_h, bSleep) && { asleep_flag: flag(n.asleep_h, bSleep) }),
    ...(n.sleep_start && flag(eveningMinutes(n.sleep_start), bBed) && { bedtime_flag: flag(eveningMinutes(n.sleep_start), bBed) === "high" ? "later than usual" : "earlier than usual" }) }));
  const avg = (xs: number[]) => (xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : null);
  const avgH = avg(ns.map((n) => n.asleep_h)), avgBed = avg(ns.filter((n) => n.sleep_start).map((n) => eveningMinutes(n.sleep_start!)));
  const nb = baseline("bedtime", addDays(to, 1));
  return {
    range: `${from}..${to}`, keyed_by: "the day you woke up", nights_with_data: ns.length, nights_in_range: daysBetween(from, to) + 1,
    average: { asleep: avgH === null ? null : hm(avgH), fell_asleep: avgBed === null ? null : fromEveningMinutes(avgBed) },
    usual_before_range: { asleep: bSleep.usual === null ? null : hm(Number(bSleep.usual)), fell_asleep: bBed.usual, days: bSleep.days, window: bSleep.window },
    ...(nb.usual !== null && { usual_fell_asleep_now: nb.usual }),
    nights: list, freshness: freshFor(["sleep_h"]), note: NO_ROW,
  };
}

const ALL_KEYS = () => [...new Set([...METRICS.map((m) => m.key), ...SLEEP_METRICS.map((m) => m.key), ...Object.keys(latestDays())])];

export function getMetrics(keys: string[], from: string, to: string, every: "day" | "week") {
  range(from, to);
  const unknown = keys.filter((k) => !ALL_KEYS().includes(k));
  if (unknown.length) throw httpErr(400, `Unknown metric ${unknown.join(", ")}. Known: ${ALL_KEYS().join(", ")}`);
  const series = keys.map((key) => {
    const def = BY_KEY.get(key), d = decimals(key);
    const vals = daily(key, from, to);
    const fmt = (v: number) => (key === "bedtime" ? fromEveningMinutes(v) : round(v, d));
    const points = every === "day"
      ? [...vals].sort(([a], [b]) => a.localeCompare(b)).map(([day, v]) => ({ day, value: fmt(v) }))
      : weekly(vals).map((w) => ({ week_of: w.start, value: fmt(w.avg), days: w.n }));
    const band = key === "heart_rate" && every === "day" ? [...heartRateBand(from, to)].sort(([a], [b]) => a.localeCompare(b)).map(([day, r]) => ({ day, min: r.min, avg: r.avg && Math.round(r.avg), max: r.max })) : undefined;
    const xs = [...vals.values()];
    const mean = xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : null;
    const b = baseline(key, from);
    return { metric: key, label: def?.label ?? key, unit: def?.unit ?? (one<{ unit: string }>("SELECT unit FROM metric_days WHERE metric=? LIMIT 1", key)?.unit ?? ""),
      better: def?.polarity ?? "neutral", days_with_data: xs.length, days_in_range: daysBetween(from, to) + 1,
      average: mean === null ? null : fmt(mean), min: xs.length ? fmt(Math.min(...xs)) : null, max: xs.length ? fmt(Math.max(...xs)) : null,
      usual_before_range: b.usual === null ? { usual: null, note: (b as { reason: string }).reason } : { usual: b.usual, range: [b.low, b.high], days: b.days },
      ...(mean !== null && b.usual !== null && "raw" in b && b.raw && key !== "bedtime" && { average_vs_usual: round(mean - b.raw.usual, d) }),
      [every === "day" ? "days" : "weeks"]: points, ...(band && { heart_rate_band: band }) };
  });
  return { range: `${from}..${to}`, every, baseline: `the ${BASELINE_DAYS} days before ${from}`, series, freshness: freshFor(keys), note: NO_ROW };
}

/** Monday-start weeks. */
function weekly(vals: Map<string, number>) {
  const weeks = new Map<string, number[]>();
  for (const [day, v] of vals) {
    const dow = (new Date(`${day}T00:00:00Z`).getUTCDay() + 6) % 7;
    const start = addDays(day, -dow);
    weeks.set(start, [...(weeks.get(start) ?? []), v]);
  }
  return [...weeks].sort(([a], [b]) => a.localeCompare(b)).map(([start, xs]) => ({ start, avg: xs.reduce((a, b) => a + b, 0) / xs.length, n: xs.length }));
}
