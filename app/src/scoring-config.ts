// v1 defaults for spec/11-scoring.md. Every tunable number lives here so a retune touches one file.

/** Spec round(): half away from zero, so −2.5 → −3 (Math.round alone gives −2). */
export function roundHalfAway(v: number, d = 0): number {
  return Math.sign(v) * Math.round(Math.abs(v) * 10 ** d) / 10 ** d;
}
export const clamp = (v: number, lo = 0, hi = 100) => Math.min(hi, Math.max(lo, v));

export const BASELINE = {
  DAYS: 60,
  MIN_BASELINE_DAYS: 7,
  MIN_SCORE_DAYS: 14,
  RANGE_LOW_Q: 0.1,
  RANGE_HIGH_Q: 0.9,
  MAD_SCALE: 1.4826,
  HRV_SPREAD_FLOOR_LN: 0.1,
  RHR_SPREAD_FLOOR_BPM: 2.0,
} as const;

export const SLEEP = {
  NEED_DEFAULT_H: 8.0,
  NEED_MIN_NIGHTS: 14,
  NEED_QUANTILE: 0.9,
  NEED_STEP_H: 0.25,
  NEED_MIN_H: 7.0,
  NEED_MAX_H: 9.0,
  DURATION_ZERO_RATIO: 0.6,
  DURATION_SPAN_RATIO: 0.4,
  CONSISTENCY_MIN_NIGHTS: 14,
  CONSISTENCY_ZERO_MIN: 120,
  ON_TIME_MIN: 5,
  EFFICIENCY_ZERO: 0.65,
  EFFICIENCY_SPAN: 0.3,
  WAKEUP_FREE: 1,
  WAKEUP_PENALTY: 10,
  AWAKE_PENALTY_PER_MIN: 0.8,
  WEIGHTS: { duration: 0.4, consistency: 0.2, efficiency: 0.2, wakeups: 0.2 },
  LABELS: { duration: "DURATION", consistency: "BEDTIME", efficiency: "EFFICIENCY", wakeups: "WAKE-UPS" },
  FLAG_BELOW: 70,
  BANDS: { good: 85, ok: 70 },
  BAND_LABELS: { good: "GOOD", ok: "OK", low: "LOW" },
} as const;

export const RECOVERY = {
  WEIGHTS: { sleep: 0.35, hrv: 0.4, resting_hr: 0.25 },
  Z_CENTRE_SCORE: 75,
  Z_POINTS: 15,
  MIN_PARTS: 2,
  BANDS: { ready: 75, steady: 60, ease: 45 },
  BAND_LABELS: { ready: "READY", steady: "STEADY", ease: "EASE", rest: "REST" },
  GUARD_Z: -1.5,
  ARROW_MIN_Z: 0.25,
  TINT_Z: 0.5,
} as const;

export const VERDICT = {
  BED_WINDOW_MIN: 90,
  // The product day rolls at 04:00 (API §4 dinner slot 18:00–03:59), so 01:00 is still "tonight".
  DAY_START_MIN: 4 * 60,
  MEAL_KCAL_LEFT_MIN: 300,
  CALL: { ready: "good", steady: "normal", ease: "as_planned_no_records", rest: "easy" },
  CALL_UNKNOWN: "unknown",
} as const;

export const DIGEST = {
  SLEEP_LINE: { good: "You slept well.", ok: "You slept okay.", low: "Short night." },
  SLEEP_LINE_NULL: "Morning.",
  RECOVERY_LINE: { ready: "Ready to push.", steady: "Steady day.", ease: "Take it easy.", rest: "Rest today." },
  RECOVERY_LINE_NULL: "Let's see how today goes.",
} as const;

export const TONIGHT = {
  DEFAULT_WAKE: "07:00",
  WAKE_MIN_NIGHTS: 7,
  WAKE_HISTORY_NIGHTS: 14,
  WAKE_ROUND_MIN: 5,
} as const;

/** §7 Training. Muscles in templates are API slugs (hyphens). */
export const TRAINING = {
  tauH: 36,
  loadWindowDays: 14,
  noDataWindowDays: 30,
  weight: { primary: 1, secondary: 0.5 },
  // Heat bands by load L: < fresh → 1, < recovering → 2, < partly → 3, else 4.
  heat: { fresh: 0.5, recovering: 2, partly: 4 },
  // Session heat by weighted sets: ≥ loaded → 4, ≥ partly → 3, > 0 → 2.
  sessionHeat: { partly: 2, loaded: 4 },
  weeklySets: { min: 10, max: 20 },
  e1rmTrend: { windowDays: 84, changeDays: 56 },
  // Splits come from the owner (Settings) and from workout names they have logged; nothing is predefined (25 Oct).
  splitHistoryDays: 90,
} as const;

/** 11 §8: weight trend, calorie, protein and steps targets. */
export const FUEL = {
  trend_alpha: 0.1,
  seed_lookback_days: 120,
  month_change_days: 30,
  initial_kcal_per_kg: 30,
  // Maintenance from the Watch: resting + active energy (Apple's resting estimate uses the Health profile's age, sex, height).
  burn_window_days: 28,
  burn_min_days: 14,
  default_kcal: 2200,
  kcal_per_kg_body: 7700,
  adapt_window_days: 21,
  min_intake_days: 14,
  min_weigh_ins: 8,
  min_intake_day_kcal: 1000,
  adapt_clamp_kcal: 150,
  kcal_floor: 1400,
  goal_deadband_kg: 0.5,
  lose_rate_per_kg: 0.005,
  lose_rate_max_kg_week: 0.75,
  gain_rate_per_kg: 0.0025,
  gain_rate_max_kg_week: 0.35,
  protein_g_per_kg: 2.0,
  default_protein_g: 140,
  steps_window_days: 28,
  steps_min_days: 7,
  default_steps: 8000,
} as const;

/** 11 §6: ahead / behind usual by now. */
export const ACTIVITY = {
  usual_window_days: 28,
  min_usual_days: 7,
  min_curve_days: 7,
  ahead_ratio: 1.1,
  behind_ratio: 0.9,
  early_steps: 300,
  early_kcal: 30,
  default_exercise_min: 30,
} as const;
