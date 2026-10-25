// Fuel (11 §8): weight trend, calorie / protein / steps targets, weekly adaptive calories. Pure: no SQL, no clock.
import { FUEL, roundHalfAway } from "./scoring-config.js";

// Same interpolated quantile as stats.ts (not imported: stats.ts pulls in db.js).
function quantile(sorted: number[], q: number) {
  const i = (sorted.length - 1) * q, lo = Math.floor(i), hi = Math.ceil(i);
  return sorted[lo] + (sorted[hi] - sorted[lo]) * (i - lo);
}
const median = (xs: number[]) => quantile([...xs].sort((a, b) => a - b), 0.5);
const isNum = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v);

export const round5 = (v: number) => roundHalfAway(v / 5) * 5;
export const round10 = (v: number) => roundHalfAway(v / 10) * 10;
export const round50 = (v: number) => roundHalfAway(v / 50) * 50;
export const round500 = (v: number) => roundHalfAway(v / 500) * 500;

export type WeightDay = { day: string; kg: number | null };
export type TrendDay = { day: string; raw_kg: number | null; trend_kg: number | null };

/** EWMA trend per consecutive day, unrounded. No seed: the first weigh-in seeds it, so earlier days carry that value. */
export function weightTrend(daily: (number | null)[], seed: number | null): (number | null)[];
export function weightTrend(daily: WeightDay[], seed: number | null): TrendDay[];
export function weightTrend(daily: (number | null)[] | WeightDay[], seed: number | null): (number | null)[] | TrendDay[] {
  const kgs = (daily as (number | null | WeightDay)[]).map((d) => (d !== null && typeof d === "object" ? d.kg : d));
  let t: number | null = isNum(seed) ? seed : kgs.find(isNum) ?? null;
  const trend = kgs.map((w) => {
    if (isNum(w) && t !== null) t += FUEL.trend_alpha * (w - t);
    return t;
  });
  if (daily.length && daily[0] !== null && typeof daily[0] === "object")
    return (daily as WeightDay[]).map((d, i) => ({ day: d.day, raw_kg: d.kg, trend_kg: trend[i] }));
  return trend;
}

/** trend today − trend 30 days ago, 1 decimal. */
export function monthChange(trendToday: number | null, trend30dAgo: number | null): number | null {
  return isNum(trendToday) && isNum(trend30dAgo) ? roundHalfAway(trendToday - trend30dAgo, 1) : null;
}

/**
 * Starting / fixed target (11 §8.2): maintenance plus the goal's rate from day one, not after the adaptive window.
 * Maintenance = measured resting + active energy when the Watch has enough days, else 30 kcal per kg.
 */
export const maintenanceKcal = (trendKg: number | null, burn: number | null = null) =>
  isNum(burn) ? round50(burn) : isNum(trendKg) ? round50(trendKg * FUEL.initial_kcal_per_kg) : FUEL.default_kcal;
export const initialKcal = (trendKg: number | null, rateKgWeek = 0, burn: number | null = null) => {
  const base = isNum(burn) ? burn : isNum(trendKg) ? trendKg * FUEL.initial_kcal_per_kg : null;
  return base === null ? FUEL.default_kcal : Math.max(round50(base + (rateKgWeek * FUEL.kcal_per_kg_body) / 7), FUEL.kcal_floor);
};
/** Mean daily resting + active kcal over days that have both; null under `burn_min_days`. */
export function measuredBurn(resting: Map<string, number>, active: Map<string, number>): number | null {
  const days = [...resting.keys()].filter((d) => active.has(d));
  return days.length < FUEL.burn_min_days ? null : days.reduce((t, d) => t + resting.get(d)! + active.get(d)!, 0) / days.length;
}
export const proteinTarget = (trendKg: number | null) => (isNum(trendKg) ? round5(trendKg * FUEL.protein_g_per_kg) : FUEL.default_protein_g);

/** Default steps target from the daily step totals of the last 28 days. */
export function stepsTarget(dailySteps28: number[]): number {
  const xs = dailySteps28.filter(isNum);
  return xs.length < FUEL.steps_min_days ? FUEL.default_steps : round500(median(xs));
}

/** Goal rate in kg/week (negative = lose); 0 inside the deadband or without a goal. */
export type Goal = "lose" | "maintain" | "gain";

/**
 * kg/week toward the goal (11 §8.2 step 5). An explicit goal sets the direction; without one the goal weight does.
 * Within 0.5 kg of the goal weight, or past it, the rate is 0.
 */
export function goalRate(goalKg: number | null, trendKg: number, goal: Goal | null = null): number {
  if (goal === "maintain") return 0;
  const diff = isNum(goalKg) ? goalKg - trendKg : null;
  const dir = goal ?? (diff === null || Math.abs(diff) <= FUEL.goal_deadband_kg ? null : diff < 0 ? "lose" : "gain");
  if (dir === null) return 0;
  if (diff !== null && (Math.abs(diff) <= FUEL.goal_deadband_kg || (dir === "lose") !== (diff < 0))) return 0;
  return dir === "lose" ? -Math.min(FUEL.lose_rate_per_kg * trendKg, FUEL.lose_rate_max_kg_week)
    : Math.min(FUEL.gain_rate_per_kg * trendKg, FUEL.gain_rate_max_kg_week);
}

export type AdaptiveInput = { intakes: (number | null)[]; weights: (number | null)[]; seed: number | null; prev: number; goal: number | null; direction?: Goal | null };
/** One `kcal_targets` row minus week_start / computed_at, plus the unclamped `raw` for display. */
export type AdaptiveKcal = {
  kcal: number; mode: "adaptive" | "kept"; tdee: number | null; intake_mean: number | null; slope_kg_day: number | null;
  rate_kg_week: number | null; raw: number | null; intake_days: number; weigh_ins: number; reason: "not_enough_data" | null;
};

/** Weekly target from the 21 days ending yesterday (intakes and weights aligned by day). Kept rows reuse `prev`. */
export function adaptiveKcal({ intakes, weights, seed, prev, goal, direction = null }: AdaptiveInput): AdaptiveKcal {
  if (intakes.length !== weights.length || weights.length < 2) throw new RangeError("intakes and weights must be the same window of ≥ 2 days");
  const eaten = intakes.filter((v): v is number => isNum(v) && v >= FUEL.min_intake_day_kcal);
  const weighIns = weights.filter(isNum).length;
  const counts = { intake_days: eaten.length, weigh_ins: weighIns };
  if (eaten.length < FUEL.min_intake_days || weighIns < FUEL.min_weigh_ins)
    return { kcal: prev, mode: "kept", tdee: null, intake_mean: null, slope_kg_day: null, rate_kg_week: null, raw: null, ...counts, reason: "not_enough_data" };

  // Endpoints are the trend on the window's first and last day (after that day's weigh-in), over n−1 day gaps.
  const trend = weightTrend(weights, seed) as number[];
  const tFirst = trend[0], tLast = trend[trend.length - 1];
  const slope = (tLast - tFirst) / (trend.length - 1);
  const intakeMean = eaten.reduce((a, b) => a + b, 0) / eaten.length;
  const tdee = intakeMean - slope * FUEL.kcal_per_kg_body;
  const rate = goalRate(goal, tLast, direction);
  const raw = tdee + (rate * FUEL.kcal_per_kg_body) / 7;
  const clamped = Math.min(Math.max(raw, prev - FUEL.adapt_clamp_kcal), prev + FUEL.adapt_clamp_kcal);
  return {
    kcal: Math.max(round10(clamped), FUEL.kcal_floor), mode: "adaptive",
    tdee: roundHalfAway(tdee), intake_mean: roundHalfAway(intakeMean), slope_kg_day: roundHalfAway(slope, 4),
    rate_kg_week: roundHalfAway(rate, 3), raw: roundHalfAway(raw), ...counts, reason: null,
  };
}
