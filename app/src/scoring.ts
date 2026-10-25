// Pure scoring for spec/11-scoring.md §2–5 and §9.2. No SQL, no clock: callers pass every input.
import { BASELINE, clamp, DIGEST, RECOVERY, roundHalfAway, SLEEP, TONIGHT, VERDICT } from "./scoring-config.js";

export type SleepBand = "good" | "ok" | "low";
export type RecoveryBand = "ready" | "steady" | "ease" | "rest";
export type PartStatus = "ok" | "calibrating" | "missing";
export type Arrow = "up" | "down" | null;
export type Tint = "good" | "watch" | null;
export type Slot = "breakfast" | "lunch" | "snack" | "dinner";

// ---------- statistics ----------

/** Linear interpolation between closest ranks; same definition as stats.ts (which imports db, so not reused). */
export function quantile(sorted: number[], q: number): number {
  const i = (sorted.length - 1) * q, lo = Math.floor(i), hi = Math.ceil(i);
  return sorted[lo] + (sorted[hi] - sorted[lo]) * (i - lo);
}
const sortedOf = (values: number[]) => [...values].sort((a, b) => a - b);
export const median = (values: number[]) => quantile(sortedOf(values), 0.5);

/** max(1.4826 × MAD, floor): MAD resists one bad night where a standard deviation would not. */
export function robustSpreadOf(values: number[], floor: number): number {
  const c = median(values);
  return Math.max(BASELINE.MAD_SCALE * median(values.map(v => Math.abs(v - c))), floor);
}

/** Weighted mean over present scores; weights scaled to integers so exact .5 totals round as the spec's vectors expect. */
function weightedMean(entries: Array<[weight: number, score: number | null]>): number | null {
  let num = 0, den = 0;
  for (const [w, s] of entries) {
    if (s === null) continue;
    const wi = Math.round(w * 1000);
    num += wi * s; den += wi;
  }
  return den === 0 ? null : num / den;
}

const pad2 = (n: number) => String(n).padStart(2, "0");
/** Minute of day → "HH:MM", wrapping across midnight. */
export const clockOf = (min: number) => { const m = ((Math.round(min) % 1440) + 1440) % 1440; return `${pad2(Math.floor(m / 60))}:${pad2(m % 60)}`; };
/** "HH:MM" → minute of day. */
export function minutesOf(hhmm: string): number {
  const m = /^(\d{2}):(\d{2})$/.exec(hhmm);
  if (!m || +m[1] > 23 || +m[2] > 59) throw new RangeError(`expected HH:MM, got ${hhmm}`);
  return +m[1] * 60 + +m[2];
}
/** 8 → "8H", 7.75 → "7H45" (need and tonight copy). */
export function hoursLabel(h: number): string {
  const t = roundHalfAway(h * 60), mm = t % 60;
  return mm === 0 ? `${Math.floor(t / 60)}H` : `${Math.floor(t / 60)}H${pad2(mm)}`;
}

// ---------- sleep (§3) ----------

export type SleepNeed = { need_h: number; basis: "target" | "history" | "default" };

/** §3.1: owner target, else the 90th percentile of asleep_h (≥ 14 nights) to the nearest 0.25 h within 7–9 h, else 8 h. */
export function sleepNeed(input: { target: number | null; asleepHistory: number[] }): SleepNeed {
  if (input.target !== null) return { need_h: input.target, basis: "target" };
  if (input.asleepHistory.length < SLEEP.NEED_MIN_NIGHTS) return { need_h: SLEEP.NEED_DEFAULT_H, basis: "default" };
  const p = quantile(sortedOf(input.asleepHistory), SLEEP.NEED_QUANTILE);
  const stepped = roundHalfAway(p / SLEEP.NEED_STEP_H) * SLEEP.NEED_STEP_H;
  return { need_h: clamp(stepped, SLEEP.NEED_MIN_H, SLEEP.NEED_MAX_H), basis: "history" };
}

const hoursBetween = (a: string | null, b: string | null) => {
  if (!a || !b) return null;
  const h = (Date.parse(b) - Date.parse(a)) / 3_600_000;
  return Number.isFinite(h) && h > 0 ? h : null;
};

/** §3.2 efficiency denominator: in-bed interval when it covers the sleep, else the sleep interval. */
export function bedHours(n: { asleep_h: number; in_bed_start: string | null; in_bed_end: string | null; sleep_start: string | null; sleep_end: string | null }): number | null {
  const inBed = hoursBetween(n.in_bed_start, n.in_bed_end);
  if (inBed !== null && inBed >= n.asleep_h) return inBed;
  return hoursBetween(n.sleep_start, n.sleep_end);
}

export const durationScore = (asleep_h: number, need_h: number) =>
  clamp(roundHalfAway(100 * (asleep_h / need_h - SLEEP.DURATION_ZERO_RATIO) / SLEEP.DURATION_SPAN_RATIO));
/** `delta_min` is signed (positive = later than usual); early and late score the same. */
export const consistencyScore = (delta_min: number) =>
  clamp(roundHalfAway(100 - Math.abs(delta_min) * 100 / SLEEP.CONSISTENCY_ZERO_MIN));
export const efficiencyScore = (asleep_h: number, bed_h: number) =>
  clamp(roundHalfAway(100 * (Math.min(1, asleep_h / bed_h) - SLEEP.EFFICIENCY_ZERO) / SLEEP.EFFICIENCY_SPAN));
/** First wake-up is free; a null term is dropped, both null → null. */
export function wakeupsScore(wakeups: number | null, awake_min: number | null): number | null {
  if (wakeups === null && awake_min === null) return null;
  const n = wakeups === null ? 0 : SLEEP.WAKEUP_PENALTY * Math.max(0, wakeups - SLEEP.WAKEUP_FREE);
  const m = awake_min === null ? 0 : SLEEP.AWAKE_PENALTY_PER_MIN * awake_min;
  return clamp(roundHalfAway(100 - n - m));
}

export type SleepPartKey = keyof typeof SLEEP.WEIGHTS;
export type SleepPart = { key: SleepPartKey; label: string; score: number | null; detail: string; flagged: boolean; weight: number; delta_min?: number | null };
export type SleepPartsInput = {
  asleep_h: number | null; need_h: number;
  /** Tonight's eveningMinutes(sleep_start); history is the window's bedtimes in the same unit. */
  bedtime_min: number | null; bedtimeHistory: number[];
  bed_h: number | null; wakeups: number | null; awake_min: number | null;
};

const part = (key: SleepPartKey, score: number | null, detail: string): SleepPart =>
  ({ key, label: SLEEP.LABELS[key], score, detail, flagged: score !== null && score < SLEEP.FLAG_BELOW, weight: SLEEP.WEIGHTS[key] });

/** §3.2–3.3 parts in API order. Stages are deliberately not an input (§1, §10.8). */
export function sleepParts(i: SleepPartsInput): SleepPart[] {
  const duration = part("duration", i.asleep_h === null ? null : durationScore(i.asleep_h, i.need_h), `OF YOUR ${hoursLabel(i.need_h)} NEED`);

  let consistency: SleepPart;
  if (i.bedtimeHistory.length < SLEEP.CONSISTENCY_MIN_NIGHTS) consistency = { ...part("consistency", null, `NEEDS ${SLEEP.CONSISTENCY_MIN_NIGHTS} NIGHTS`), delta_min: null };
  else if (i.bedtime_min === null) consistency = { ...part("consistency", null, "NO BEDTIME"), delta_min: null };
  else {
    const d = i.bedtime_min - median(i.bedtimeHistory), shown = roundHalfAway(d);
    const detail = Math.abs(d) < SLEEP.ON_TIME_MIN ? "ON TIME" : `${Math.abs(shown)} MIN ${d > 0 ? "LATE" : "EARLY"}`;
    consistency = { ...part("consistency", consistencyScore(d), detail), delta_min: shown };
  }

  const efficiency = i.bed_h === null || i.asleep_h === null
    ? part("efficiency", null, "NO IN-BED TIME")
    : part("efficiency", efficiencyScore(i.asleep_h, i.bed_h), `${roundHalfAway(Math.min(1, i.asleep_h / i.bed_h) * 100)}% ASLEEP`);

  const n = i.wakeups, m = i.awake_min === null ? null : roundHalfAway(i.awake_min);
  const wakeDetail = n !== null && m !== null ? `${n} · ${m} MIN` : m !== null ? `${m} MIN AWAKE` : n !== null ? `${n} WAKE-UP${n === 1 ? "" : "S"}` : "NO WAKE DATA";
  const wakeups = part("wakeups", wakeupsScore(i.wakeups, i.awake_min), wakeDetail);

  return [duration, consistency, efficiency, wakeups];
}

export function sleepBand(score: number | null): SleepBand | null {
  if (score === null) return null;
  return score >= SLEEP.BANDS.good ? "good" : score >= SLEEP.BANDS.ok ? "ok" : "low";
}

/** §3.3: re-normalised over present parts; no score without duration. */
export function sleepScore(parts: Array<Pick<SleepPart, "key" | "score">>): { score: number | null; band: SleepBand | null; label: string | null } {
  const duration = parts.find(p => p.key === "duration");
  const mean = duration?.score == null ? null : weightedMean(parts.map(p => [SLEEP.WEIGHTS[p.key], p.score]));
  const score = mean === null ? null : roundHalfAway(mean);
  const band = sleepBand(score);
  return { score, band, label: band && SLEEP.BAND_LABELS[band] };
}

// ---------- recovery (§2, §4) ----------

export type HeartPart = {
  value: number | null; usual: number | null; usual_range: [number, number] | null;
  /** Rounded to 2 decimals for display; `z_raw` drives the guard. Both in the better-is-positive direction. */
  z: number | null; z_raw: number | null;
  score: number | null; arrow: Arrow; tint: Tint; status: PartStatus; nights: number; nights_needed: number;
};

/** Arrow follows the raw value (RHR 57 vs 55 is "up"); tint follows the better-direction z. */
export function displayHints(above: boolean, z: number | null): { arrow: Arrow; tint: Tint } {
  if (z === null) return { arrow: null, tint: null };
  const arrow: Arrow = Math.abs(z) >= RECOVERY.ARROW_MIN_Z ? (above ? "up" : "down") : null;
  const tint: Tint = z >= RECOVERY.TINT_Z ? "good" : z <= -RECOVERY.TINT_Z ? "watch" : null;
  return { arrow, tint };
}

function heartPart(value: number | null, history: number[], o: { log: boolean; floor: number; lowerIsBetter: boolean; decimals: number }): HeartPart {
  const hist = history.filter(v => Number.isFinite(v) && (!o.log || v > 0));
  const n = hist.length, sorted = sortedOf(hist);
  const shown = (v: number) => roundHalfAway(v, o.decimals);
  const hasRange = n >= BASELINE.MIN_BASELINE_DAYS;
  const nights_needed = Math.max(0, BASELINE.MIN_SCORE_DAYS - n);
  const valid = value !== null && Number.isFinite(value) && (!o.log || value > 0);
  const status: PartStatus = !valid ? "missing" : nights_needed > 0 ? "calibrating" : "ok";
  const out: HeartPart = {
    value, usual: hasRange ? shown(quantile(sorted, 0.5)) : null,
    usual_range: hasRange ? [shown(quantile(sorted, BASELINE.RANGE_LOW_Q)), shown(quantile(sorted, BASELINE.RANGE_HIGH_Q))] : null,
    z: null, z_raw: null, score: null, arrow: null, tint: null, status, nights: n, nights_needed,
  };
  if (status !== "ok" || value === null) return out;
  const t = o.log ? Math.log : (v: number) => v;
  const space = hist.map(t), centre = median(space), spread = robustSpreadOf(space, o.floor);
  const diff = t(value) - centre;
  const z = ((o.lowerIsBetter ? -diff : diff) / spread) || 0; // flipping a zero diff yields −0
  return { ...out, z: roundHalfAway(z, 2), z_raw: z, score: clamp(roundHalfAway(RECOVERY.Z_CENTRE_SCORE + RECOVERY.Z_POINTS * z)), ...displayHints(diff > 0, z) };
}

/** HRV is scored in ln space (§2); usual and range stay in ms. */
export const hrvPart = (value_ms: number | null, history_ms: number[]) =>
  heartPart(value_ms, history_ms, { log: true, floor: BASELINE.HRV_SPREAD_FLOOR_LN, lowerIsBetter: false, decimals: 1 });
/** Sign flipped: a lower resting HR than usual is the better direction. */
export const rhrPart = (value_bpm: number | null, history_bpm: number[]) =>
  heartPart(value_bpm, history_bpm, { log: false, floor: BASELINE.RHR_SPREAD_FLOOR_BPM, lowerIsBetter: true, decimals: 0 });

export function recoveryBand(score: number | null): RecoveryBand | null {
  if (score === null) return null;
  const b = RECOVERY.BANDS;
  return score >= b.ready ? "ready" : score >= b.steady ? "steady" : score >= b.ease ? "ease" : "rest";
}

export type Recovery = {
  score: number | null; band: RecoveryBand | null; label: string | null; status: PartStatus;
  reason: string | null; nights_needed: number;
  /** True only when the guard lowered the band (a band already at ease/rest is not "applied"). */
  guard_applied: boolean;
};
type HeartIn = Pick<HeartPart, "score" | "z_raw" | "status" | "nights_needed"> | null;

/** §4: needs ≥ 2 parts including HRV or resting HR; calibrating beats missing when a heart baseline is short. */
export function recoveryScore(i: { sleep: number | null; hrv: HeartIn; rhr: HeartIn }): Recovery {
  const hrv = i.hrv?.score ?? null, rhr = i.rhr?.score ?? null;
  const present = [i.sleep, hrv, rhr].filter(s => s !== null).length;
  if (present < RECOVERY.MIN_PARTS || (hrv === null && rhr === null)) {
    const calibrating = [i.hrv, i.rhr].filter(p => p?.status === "calibrating").map(p => p!.nights_needed);
    if (calibrating.length) {
      const nights = Math.min(...calibrating);
      return { score: null, band: null, label: null, status: "calibrating", reason: `Needs ${nights} more night${nights === 1 ? "" : "s"}`, nights_needed: nights, guard_applied: false };
    }
    const reason = i.sleep === null ? "No sleep recorded for last night" : "No heart data for last night";
    return { score: null, band: null, label: null, status: "missing", reason, nights_needed: 0, guard_applied: false };
  }
  const w = RECOVERY.WEIGHTS;
  const score = roundHalfAway(weightedMean([[w.sleep, i.sleep], [w.hrv, hrv], [w.resting_hr, rhr]])!);
  let band = recoveryBand(score)!;
  const guard = (i.hrv?.z_raw ?? Infinity) <= RECOVERY.GUARD_Z && (i.rhr?.z_raw ?? Infinity) <= RECOVERY.GUARD_Z;
  const guard_applied = guard && (band === "ready" || band === "steady");
  if (guard_applied) band = "ease";
  return { score, band, label: RECOVERY.BAND_LABELS[band], status: "ok", reason: null, nights_needed: 0, guard_applied };
}

// ---------- verdict (§5) ----------

export type VerdictAction =
  | { kind: "bed_reminder"; label: string }
  | { kind: "log_meal"; label: string; slot: Slot }
  | { kind: "start_workout"; label: string; template: null; intensity: "normal" | "light" };
export type Verdict = { band: RecoveryBand | null; label: string | null; headline: string; reason: string; action: VerdictAction; rule: number };
export type VerdictInput = {
  recovery: { band: RecoveryBand | null; score: number | null; reason?: string | null };
  /** Part hints for the one-line reason; optional. */
  hints?: { hrv?: { arrow: Arrow; tint: Tint } | null; resting_hr?: { arrow: Arrow; tint: Tint } | null };
  /** Some split is ready, or none exist yet (§7.3); the verdict never names one. */
  trainable: boolean;
  strength_today: { title: string; sets: number } | null;
  kcal_left: number | null;
  next_slot: Slot;
  /** Local minute of day now, and tonight's bed_by as minute of day (null skips rule 1). */
  now_min: number;
  bed_by_min: number | null;
};

const sinceDayStart = (min: number) => (((min - VERDICT.DAY_START_MIN) % 1440) + 1440) % 1440;
const bedReminder = (): VerdictAction => ({ kind: "bed_reminder", label: "Remind me" });
const logMeal = (slot: Slot): VerdictAction => ({ kind: "log_meal", label: `Log ${slot}`, slot });
const startWorkout = (light = false): VerdictAction => ({
  kind: "start_workout", template: null, intensity: light ? "light" : "normal", label: light ? "Start light workout" : "Start workout",
});

function recoveryReason(i: VerdictInput): string {
  const h = i.hints?.hrv, r = i.hints?.resting_hr;
  const hrv = h?.arrow === "up" ? "HRV above your usual" : h?.arrow === "down" ? "HRV below your usual" : "HRV near your usual";
  const rhrDir = r?.arrow === "up" ? "up" : r?.arrow === "down" ? "down" : null;
  const rhr = rhrDir === null ? "resting heart rate steady" : `resting heart rate ${r?.tint === null ? "slightly " : ""}${rhrDir}`;
  return `Recovery ${i.recovery.score}: ${hrv}, ${rhr}.`;
}

/** §5 rule table, first match wins; `rule` is the matching row number. */
export function verdict(i: VerdictInput): Verdict {
  const band = i.recovery.band, label = band ? RECOVERY.BAND_LABELS[band] : null;
  const out = (rule: number, headline: string, reason: string, action: VerdictAction): Verdict => ({ band, label, headline, reason, action, rule });

  if (i.bed_by_min !== null && sinceDayStart(i.now_min) >= sinceDayStart(i.bed_by_min) - VERDICT.BED_WINDOW_MIN)
    return out(1, `Bed by ${clockOf(i.bed_by_min)}`, "Winding down now protects tonight's sleep.", bedReminder());
  if (i.strength_today) {
    const meal = i.kcal_left !== null && i.kcal_left > VERDICT.MEAL_KCAL_LEFT_MIN;
    return out(2, "Done for today", `${i.strength_today.title}, ${i.strength_today.sets} sets.`, meal ? logMeal(i.next_slot) : bedReminder());
  }
  if (band === null) {
    const reason = i.recovery.reason ?? "No recovery score yet.";
    return i.trainable ? out(3, "Fresh to train", reason, startWorkout()) : out(4, "No score yet", reason, logMeal(i.next_slot));
  }
  if (band === "rest") {
    const food = i.kcal_left === null || i.kcal_left > 0;
    return out(9, "Rest today", recoveryReason(i), food ? logMeal(i.next_slot) : bedReminder());
  }
  if (!i.trainable) return out(8, "Muscles still loaded", recoveryReason(i), logMeal(i.next_slot));
  if (band === "ready") return out(5, "Train hard today", recoveryReason(i), startWorkout());
  if (band === "steady") return out(6, "Train as planned", recoveryReason(i), startWorkout());
  return out(7, "Go easy today", `${recoveryReason(i)} No records today.`, startWorkout(true));
}

/** Legacy MCP `get_brief.verdict.call`, derived from the band. */
export const verdictCall = (band: RecoveryBand | null): string => (band ? VERDICT.CALL[band] : VERDICT.CALL_UNKNOWN);

/** §5.1 two-line digest headline; keyed on bands only (status does not change the copy). */
export function digestHeadline(sleepBand: SleepBand | null, recoveryBand: RecoveryBand | null): [string, string] {
  return [sleepBand ? DIGEST.SLEEP_LINE[sleepBand] : DIGEST.SLEEP_LINE_NULL, recoveryBand ? DIGEST.RECOVERY_LINE[recoveryBand] : DIGEST.RECOVERY_LINE_NULL];
}

// ---------- tonight (§9.2) ----------

export type Tonight = { wake_time: string; bed_by: string; bed_by_min: number; need_h: number; label: string; wake_basis: "target" | "history" | "default" };

/** wakeHistoryMin = clock minutes of sleep_end for the last 14 nights; median needs ≥ 7 and is rounded to 5 min. */
export function tonight(i: { wakeTarget: string | null; wakeHistoryMin: number[]; need_h: number }): Tonight {
  let wake: number, wake_basis: Tonight["wake_basis"];
  if (i.wakeTarget !== null) { wake = minutesOf(i.wakeTarget); wake_basis = "target"; }
  else if (i.wakeHistoryMin.length >= TONIGHT.WAKE_MIN_NIGHTS) {
    wake = roundHalfAway(median(i.wakeHistoryMin) / TONIGHT.WAKE_ROUND_MIN) * TONIGHT.WAKE_ROUND_MIN; wake_basis = "history";
  } else { wake = minutesOf(TONIGHT.DEFAULT_WAKE); wake_basis = "default"; }
  const bed_by_min = (((wake - roundHalfAway(i.need_h * 60)) % 1440) + 1440) % 1440;
  const wake_time = clockOf(wake);
  return { wake_time, bed_by: clockOf(bed_by_min), bed_by_min, need_h: i.need_h, label: `${hoursLabel(i.need_h)} BEFORE YOUR ${wake_time} WAKE`, wake_basis };
}
