// Per-day values and personal baselines. A baseline is the median of the 30 days before the day asked about, with the
// 10th–90th percentile as the usual range; a value outside that range is flagged. Fewer than 7 days gives no baseline.
import { BY_KEY, type MetricDef } from "./catalog.js";
import { all } from "./db.js";
import { addDays, clock, eveningMinutes, fromEveningMinutes } from "./time.js";

export const BASELINE_DAYS = 30;
export const MIN_BASELINE_DAYS = 7;

type MetricRow = { day: string; source: string; qty: number | null; min: number | null; avg: number | null; max: number | null };
export type Night = { day: string; source: string; sleep_start: string | null; sleep_end: string | null; in_bed_start: string | null;
  in_bed_end: string | null; asleep_h: number; core_h: number | null; deep_h: number | null; rem_h: number | null; awake_h: number | null };

// When several sources report one day, the merged total ('') wins, then the Watch, then whatever came first.
const rank = (s: string) => (s === "" ? 0 : /watch/i.test(s) ? 1 : 2);
function pickPerDay<T extends { day: string; source: string }>(rows: T[]): Map<string, T> {
  const m = new Map<string, T>();
  for (const r of rows) { const cur = m.get(r.day); if (!cur || rank(r.source) < rank(cur.source)) m.set(r.day, r); }
  return m;
}

export function nights(from: string, to: string): Night[] {
  const rows = all<Night>("SELECT day,source,sleep_start,sleep_end,in_bed_start,in_bed_end,asleep_h,core_h,deep_h,rem_h,awake_h FROM sleep_nights WHERE day BETWEEN ? AND ? ORDER BY day", from, to);
  return [...pickPerDay(rows).values()].sort((a, b) => a.day.localeCompare(b.day));
}

/** Day → value for one metric. heart_rate's value is the daily average; bedtime is minutes past 18:00. */
export function daily(key: string, from: string, to: string): Map<string, number> {
  const out = new Map<string, number>();
  if (key === "sleep_h" || key === "deep_h" || key === "rem_h" || key === "bedtime") {
    for (const n of nights(from, to)) {
      const v = key === "sleep_h" ? n.asleep_h : key === "deep_h" ? n.deep_h : key === "rem_h" ? n.rem_h : n.sleep_start ? eveningMinutes(n.sleep_start) : null;
      if (v !== null && v !== undefined) out.set(n.day, v);
    }
    return out;
  }
  const rows = all<MetricRow>("SELECT day,source,qty,min,avg,max FROM metric_days WHERE metric=? AND day BETWEEN ? AND ?", key, from, to);
  for (const [day, r] of pickPerDay(rows)) { const v = r.qty ?? r.avg; if (v !== null) out.set(day, v); }
  return out;
}

export function heartRateBand(from: string, to: string) {
  const rows = all<MetricRow>("SELECT day,source,qty,min,avg,max FROM metric_days WHERE metric='heart_rate' AND day BETWEEN ? AND ?", from, to);
  return pickPerDay(rows);
}

function quantile(sorted: number[], q: number) {
  const i = (sorted.length - 1) * q, lo = Math.floor(i), hi = Math.ceil(i);
  return sorted[lo] + (sorted[hi] - sorted[lo]) * (i - lo);
}

export type Baseline = { usual: number | string; low: number | string; high: number | string; days: number; window: string; method: string }
  | { usual: null; days: number; window: string; reason: string };

/** Baseline for `day`, from the BASELINE_DAYS before it (the day itself excluded). */
export function baseline(key: string, day: string): Baseline & { raw?: { usual: number; low: number; high: number } } {
  const from = addDays(day, -BASELINE_DAYS), to = addDays(day, -1);
  const vals = [...daily(key, from, to).values()].sort((a, b) => a - b);
  const window = `${from}..${to}`;
  if (vals.length < MIN_BASELINE_DAYS) return { usual: null, days: vals.length, window, reason: `only ${vals.length} of the ${MIN_BASELINE_DAYS} days needed` };
  const raw = { usual: quantile(vals, 0.5), low: quantile(vals, 0.1), high: quantile(vals, 0.9) };
  const fmt = (v: number) => (key === "bedtime" ? fromEveningMinutes(v) : round(v, decimals(key)));
  return { usual: fmt(raw.usual), low: fmt(raw.low), high: fmt(raw.high), days: vals.length, window, method: "median; usual range is the 10th to 90th percentile", raw };
}

export type Compared = { value: number | string; unit: string; usual: number | string | null; usual_range?: [number | string, number | string];
  delta?: number; flag?: "low" | "high"; reading?: "better" | "worse"; baseline_days: number; baseline_note?: string };

/** One day's value set against the owner's own baseline. Server-side arithmetic, so agents quote it rather than compute it. */
export function compare(key: string, day: string, value: number): Compared {
  const def = BY_KEY.get(key) as MetricDef | undefined;
  const b = baseline(key, day);
  const shown = key === "bedtime" ? fromEveningMinutes(value) : round(value, decimals(key));
  const unit = def?.unit ?? "";
  if (b.usual === null || !b.raw) return { value: shown, unit, usual: null, baseline_days: b.days, baseline_note: (b as { reason: string }).reason };
  const out: Compared = { value: shown, unit, usual: b.usual, usual_range: [b.low, b.high], baseline_days: b.days,
    delta: key === "bedtime" ? Math.round(value - b.raw.usual) : round(value - b.raw.usual, decimals(key)) };
  if (value < b.raw.low) out.flag = "low";
  else if (value > b.raw.high) out.flag = "high";
  if (out.flag && def && def.polarity !== "neutral") out.reading = (out.flag === "high") === (def.polarity === "higher") ? "better" : "worse";
  if (key === "bedtime" && out.flag) out.reading = out.flag === "high" ? "worse" : "better";
  return out;
}

export const decimals = (key: string) => (["steps", "flights", "stand_hours", "resting_hr", "walking_hr", "heart_rate", "active_kcal", "resting_kcal", "exercise_min", "daylight_min"].includes(key) ? 0 : key.endsWith("_h") ? 2 : 1);
export const round = (v: number, d = 1) => Math.round(v * 10 ** d) / 10 ** d;
export const hm = (h: number) => { const m = Math.round(h * 60); return `${Math.floor(m / 60)}h ${String(m % 60).padStart(2, "0")}m`; };
export { clock };
