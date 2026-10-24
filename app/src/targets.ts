// Owner targets (spec 10 §3, 12 §2.4): stored values, the computed defaults scoring uses, and suggestions for setup.
// Only keys the owner set are stored; everything else is computed on read so it follows their data.
import { z } from "zod";
import { now } from "./config.js";
import { all, bumpTargetsVersion, run, tx } from "./db.js";
import { kcalTargetFor, markAllScoresStale, needFor, tonightFor, trendOn } from "./derived.js";
import { initialKcal, proteinTarget, stepsTarget } from "./fuel.js";
import { freshnessBlock } from "./health.js";
import { ApiError } from "./http.js";
import { roundHalfAway } from "./scoring-config.js";
import { daily } from "./stats.js";
import { addDays, today } from "./time.js";
import { weekStartOf } from "./training-analytics.js";

const CROWN_STEPS = [0.5, 1, 1.25, 2, 2.5, 5] as const;
const int = (lo: number, hi: number) => z.number().int().min(lo).max(hi);
const FIELDS = {
  steps: int(1000, 50000), kcal_mode: z.enum(["adaptive", "fixed"]), kcal: int(1000, 6000), protein_g: int(30, 400),
  sleep_need_h: z.number().min(5).max(11).refine((v) => Number.isInteger(v * 4), "must be a multiple of 0.25"),
  wake_time: z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/, "must be HH:MM"), goal_weight_kg: z.number().min(30).max(300),
  exercise_min: int(0, 300), weekly_sets_min: int(0, 60), weekly_sets_max: int(0, 60), rest_s: int(15, 600),
  crown_step_kg: z.number().refine((v) => (CROWN_STEPS as readonly number[]).includes(v), `must be one of ${CROWN_STEPS.join(", ")}`),
};
export type TargetKey = keyof typeof FIELDS;
export const TARGET_KEYS = Object.keys(FIELDS) as TargetKey[];
/** PUT body: any subset of keys (unknown keys are 422); null clears a key back to its computed default. */
export const putSchema = z.strictObject(Object.fromEntries(TARGET_KEYS.map((k) => [k, (FIELDS[k] as z.ZodType).nullable().optional()])) as unknown as Record<TargetKey, z.ZodOptional<z.ZodNullable<z.ZodType>>>);

const FIXED_DEFAULTS = { exercise_min: 30, weekly_sets_min: 10, weekly_sets_max: 20, rest_s: 120, crown_step_kg: 2.5 } as const;

export function storedTargets(): Partial<Record<TargetKey, unknown>> {
  return Object.fromEntries(all<{ key: string; value_json: string }>("SELECT key,value_json FROM targets").map((r) => [r.key, JSON.parse(r.value_json)]));
}

const fmt = (n: number) => Math.round(n).toLocaleString("en-US");

/** Everything scoring and the screens need, for the owner's local day at `at`. */
export function effectiveTargets(at = Date.now()) {
  const day = today(at), v = storedTargets();
  const steps28 = [...daily("steps", addDays(day, -28), addDays(day, -1)).values()];
  const trend = trendOn(day), need = needFor(day), night = tonightFor(day);
  const kcalMode = (v.kcal_mode as string | undefined) ?? "adaptive";
  const kcal = kcalMode === "fixed" ? (v.kcal as number | undefined) ?? initialKcal(trend) : kcalTargetFor(weekStartOf(day)).kcal;
  return {
    steps: (v.steps as number | undefined) ?? stepsTarget(steps28), kcal, kcal_mode: kcalMode,
    protein_g: (v.protein_g as number | undefined) ?? proteinTarget(trend), sleep_need_h: need.need_h, need_basis: need.basis,
    wake_time: night.wake_time, bed_by: night.bed_by, bed_by_min: night.bed_by_min,
    exercise_min: (v.exercise_min as number | undefined) ?? FIXED_DEFAULTS.exercise_min,
    weekly_sets_min: (v.weekly_sets_min as number | undefined) ?? FIXED_DEFAULTS.weekly_sets_min,
    weekly_sets_max: (v.weekly_sets_max as number | undefined) ?? FIXED_DEFAULTS.weekly_sets_max,
    rest_s: (v.rest_s as number | undefined) ?? FIXED_DEFAULTS.rest_s, crown_step_kg: (v.crown_step_kg as number | undefined) ?? FIXED_DEFAULTS.crown_step_kg,
    goal_weight_kg: (v.goal_weight_kg as number | undefined) ?? null, trend_kg: trend, steps28,
  };
}

/** GET /v2/targets body. */
export function getTargets(at = Date.now()) {
  const v = storedTargets(), e = effectiveTargets(at);
  const computedNeed = needFor(today(at), true);
  return {
    values: Object.fromEntries(TARGET_KEYS.map((k) => [k, v[k] ?? null])),
    effective: { steps: e.steps, kcal: e.kcal, protein_g: e.protein_g, sleep_need_h: e.sleep_need_h, wake_time: e.wake_time, bed_by: e.bed_by },
    suggested: {
      steps: { value: stepsTarget(e.steps28), basis: e.steps28.length >= 7 ? `YOUR USUAL IS ${fmt(medianOf(e.steps28))}` : "DEFAULT UNTIL 7 DAYS" },
      kcal: { value: e.kcal_mode === "fixed" ? initialKcal(e.trend_kg) : e.kcal, basis: e.kcal_mode === "fixed" ? "30 KCAL PER KG" : "ADJUSTS WEEKLY FROM WEIGHT" },
      protein_g: { value: proteinTarget(e.trend_kg), basis: e.trend_kg === null ? "NO WEIGHT YET" : "2.0 G PER KG" },
      sleep_need_h: { value: computedNeed.need_h, basis: computedNeed.basis === "history" ? "FROM YOUR LAST 60 NIGHTS" : "DEFAULT UNTIL 14 NIGHTS" },
      goal_weight_kg: { value: null, basis: e.trend_kg === null ? "NO WEIGHT YET" : `NOW ${roundHalfAway(e.trend_kg, 1).toFixed(1)} KG` },
    },
    is_set: Object.fromEntries(TARGET_KEYS.map((k) => [k, v[k] !== undefined])),
    freshness: freshnessBlock(at),
  };
}
const medianOf = (xs: number[]) => {
  const s = [...xs].sort((a, b) => a - b), i = (s.length - 1) / 2;
  return (s[Math.floor(i)] + s[Math.ceil(i)]) / 2;
};

/** PUT /v2/targets: partial update in one transaction; returns nothing (the route re-reads). */
export function putTargets(input: Partial<Record<TargetKey, unknown>>, at = Date.now()) {
  const merged = { ...storedTargets() } as Record<string, unknown>;
  for (const [k, val] of Object.entries(input)) if (val === null) delete merged[k]; else if (val !== undefined) merged[k] = val;
  const lo = (merged.weekly_sets_min as number | undefined) ?? FIXED_DEFAULTS.weekly_sets_min, hi = (merged.weekly_sets_max as number | undefined) ?? FIXED_DEFAULTS.weekly_sets_max;
  if (lo > hi) throw new ApiError(422, "weekly_sets_min: must not be above weekly_sets_max", "invalid");
  tx(() => {
    for (const [k, val] of Object.entries(input)) {
      if (val === undefined) continue;
      if (val === null) run("DELETE FROM targets WHERE key=?", k);
      else run("INSERT INTO targets(key,value_json,updated_at) VALUES(?,?,?) ON CONFLICT(key) DO UPDATE SET value_json=excluded.value_json,updated_at=excluded.updated_at", k, JSON.stringify(val), now());
    }
    bumpTargetsVersion();
    markAllScoresStale();
    if (["goal_weight_kg", "kcal_mode", "kcal"].some((k) => k in input)) kcalTargetFor(weekStartOf(today(at)), true);
  });
}
