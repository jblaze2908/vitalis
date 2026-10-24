// Activity (11 §6): per-day cumulative curves and ahead / behind usual by now. Pure: no SQL, no clock.
import { ACTIVITY, roundHalfAway } from "./scoring-config.js";

// Same interpolated quantile as stats.ts (not imported: stats.ts pulls in db.js).
function quantile(sorted: number[], q: number) {
  const i = (sorted.length - 1) * q, lo = Math.floor(i), hi = Math.ceil(i);
  return sorted[lo] + (sorted[hi] - sorted[lo]) * (i - lo);
}
const median = (xs: number[]) => quantile([...xs].sort((a, b) => a - b), 0.5);
const isNum = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v);
const HOUR = 3_600_000;

export type Sample = { start_ms: number; end_ms: number; value: number; source: string };
export type Pace = "ahead" | "behind" | "on_pace" | "early" | "unknown";

/** 24 cumulative fractions from the source with the largest in-day total; equal totals go to the smaller source name
 *  (pickPerDay's cumulative tie rule). Values split across hours by overlap; the part outside the day is dropped. */
export function curveFromSamples(samples: Sample[], day: string, offsetMin: number): number[] | null {
  const dayStart = Date.parse(`${day}T00:00:00Z`) - offsetMin * 60_000, dayEnd = dayStart + 24 * HOUR;
  const bySource = new Map<string, number[]>();
  for (const s of samples) {
    if (!isNum(s.value) || s.value <= 0 || !isNum(s.start_ms) || !isNum(s.end_ms) || s.end_ms < s.start_ms) continue;
    const hours = bySource.get(s.source) ?? new Array<number>(24).fill(0);
    const dur = s.end_ms - s.start_ms;
    if (dur === 0) {
      if (s.start_ms < dayStart || s.start_ms >= dayEnd) continue;
      hours[Math.floor((s.start_ms - dayStart) / HOUR)] += s.value;
    } else {
      const from = Math.max(s.start_ms, dayStart), to = Math.min(s.end_ms, dayEnd);
      if (to <= from) continue;
      for (let h = Math.floor((from - dayStart) / HOUR); h < 24 && dayStart + h * HOUR < to; h++) {
        const overlap = Math.min(to, dayStart + (h + 1) * HOUR) - Math.max(from, dayStart + h * HOUR);
        if (overlap > 0) hours[h] += (s.value * overlap) / dur;
      }
    }
    bySource.set(s.source, hours);
  }
  let best: { source: string; total: number; hours: number[] } | null = null;
  for (const [source, hours] of bySource) {
    const total = hours.reduce((a, b) => a + b, 0);
    if (!best || total > best.total || (total === best.total && source < best.source)) best = { source, total, hours };
  }
  if (!best || best.total <= 0) return null;
  let cum = 0;
  const f = best.hours.map((v) => (cum += v) / best.total);
  f[23] = 1; // float sums can land a hair off 1
  return f;
}

/** f at `minuteOfDay` for one curve: 0 at midnight, f[h] at the end of hour h, linear within the hour. */
function fractionAt(curve: number[], minuteOfDay: number) {
  const m = Math.min(Math.max(minuteOfDay, 0), 1440);
  const h = Math.min(Math.floor(m / 60), 23), start = h === 0 ? 0 : curve[h - 1];
  return start + (curve[h] - start) * ((m - h * 60) / 60);
}

/** Median usual fraction of the day's total reached by now; null with fewer than 7 curve days. */
export function usualFractionNow(curves: number[][], minuteOfDay: number): number | null {
  const ok = curves.filter((c) => Array.isArray(c) && c.length === 24);
  return ok.length < ACTIVITY.min_curve_days ? null : median(ok.map((c) => fractionAt(c, minuteOfDay)));
}

/** Median merged daily total over the 28 days before today; null with fewer than 7 days. */
export function usualTotal(dailyTotals28: number[]): number | null {
  const xs = dailyTotals28.filter(isNum);
  return xs.length < ACTIVITY.min_usual_days ? null : median(xs);
}

/** E = U × F(t), rounded for the `*_expected_now` fields; null when either side is. */
export const expectedNow = (usual: number | null, fraction: number | null) =>
  isNum(usual) && isNum(fraction) ? roundHalfAway(usual * fraction) : null;

export function pace(today: number | null, expected: number | null, kind: "steps" | "kcal"): Pace {
  if (!isNum(today) || !isNum(expected)) return "unknown";
  if (expected < (kind === "steps" ? ACTIVITY.early_steps : ACTIVITY.early_kcal)) return "early";
  if (today >= ACTIVITY.ahead_ratio * expected) return "ahead";
  if (today <= ACTIVITY.behind_ratio * expected) return "behind";
  return "on_pace";
}

const LABELS: Partial<Record<Pace, string>> = { ahead: "AHEAD", behind: "BEHIND", on_pace: "ON PACE" };
export const paceLabel = (p: Pace): string | null => LABELS[p] ?? null;
