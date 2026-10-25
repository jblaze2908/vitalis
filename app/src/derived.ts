// Compute on read with a per-day cache (spec 12 §3). Features depend on one day's inputs; scores on that day plus the 60
// before it, cached for days ≤ today − 2. Ingest and every write route call markDirty inside their transaction.
// Cost: a warm GET reads ~61 daily_derived rows plus a few indexed lookups; a cold window computes 61 days once, then caches.
import { curveFromSamples } from "./activity.js";
import { getExercise } from "./exercises.js";
import { all, bumpDataVersion, dataVersions, db, one, run } from "./db.js";
import { adaptiveKcal, goalRate, initialKcal, measuredBurn, weightTrend, type Goal } from "./fuel.js";
import { bedHours, hrvPart, recoveryScore, rhrPart, sleepNeed, sleepParts, sleepScore, tonight } from "./scoring.js";
import { BASELINE_DAYS, MIN_SCORE_DAYS, daily, naps, nights, type Night } from "./stats.js";
import { addDays, DAY_RE, eveningMinutes, localDay, ownerOffsetMin, today as todayOf } from "./time.js";
import { freshLabel, freshness, loadedLabel, sessionMuscles, SLUGS, splitStates, type SplitCandidate, type TrainingSet } from "./training-analytics.js";
import { FUEL, roundHalfAway, SLEEP, TRAINING } from "./scoring-config.js";

const HOUR = 3_600_000;

/** Days changed by a write: their features and the scores of every day whose 60-day window contains them go stale. */
export function markDirty(days: string[]) {
  const valid = [...new Set(days)].filter((d) => DAY_RE.test(d)).sort();
  if (valid.length) {
    run(`INSERT INTO daily_derived(day) SELECT value FROM json_each(?) WHERE true
      ON CONFLICT(day) DO UPDATE SET features_stale=1`, JSON.stringify(valid));
    run("UPDATE daily_derived SET scores_stale=1 WHERE day BETWEEN ? AND ?", valid[0], addDays(valid.at(-1)!, BASELINE_DAYS));
  }
  bumpDataVersion();
}

/** Targets change sleep need and therefore every duration part. */
export function markAllScoresStale() { run("UPDATE daily_derived SET scores_stale=1"); }

/** The owner's stored target value (JSON), or null when unset. */
export function storedTarget<T = unknown>(key: string): T | null {
  const r = one<{ value_json: string }>("SELECT value_json FROM targets WHERE key=?", key);
  return r ? JSON.parse(r.value_json) as T : null;
}

const isBusy = (e: unknown) => [5, 6].includes(((e as { errcode?: number }).errcode ?? 0) & 255);
/**
 * Best-effort cache write from a read: never waits on the ingest worker's lock, and is skipped when any write landed
 * since `version` was read (that write marked the rows dirty after this computation started).
 */
function cacheWrite(version: number, fn: () => void) {
  db.exec("PRAGMA busy_timeout=0");
  try {
    db.exec("BEGIN IMMEDIATE");
    try {
      if (dataVersions().data === version) fn();
      db.exec("COMMIT");
    } catch (e) { try { db.exec("ROLLBACK"); } catch { /* already rolled back */ } throw e; }
  } catch (e) { if (!isBusy(e)) throw e; }
  finally { db.exec("PRAGMA busy_timeout=3000"); }
}

export type Features = { day: string; asleep_h: number | null; bedtime_min: number | null; bed_h: number | null; wakeups: number | null;
  awake_min: number | null; hrv_ms: number | null; hrv_basis: "overnight" | "daily" | null; rhr_bpm: number | null;
  steps_curve: number[] | null; kcal_curve: number[] | null };
type DerivedRow = { day: string; asleep_h: number | null; bedtime_min: number | null; bed_h: number | null; wakeups: number | null;
  awake_min: number | null; hrv_ms: number | null; hrv_basis: "overnight" | "daily" | null; rhr_bpm: number | null; steps_curve: string | null;
  kcal_curve: string | null; features_at: number | null; features_stale: number; sleep_json: string | null; recovery_json: string | null;
  scores_at: number | null; scores_stale: number };

const rank = (s: string) => (s === "" ? 0 : /watch/i.test(s) ? 1 : 2);
const pickSource = (sources: Iterable<string>) => [...new Set(sources)].sort((a, b) => rank(a) - rank(b) || a.localeCompare(b))[0];

type RawPoint = { start_ms: number; end_ms: number; value: number; source: string };
/** Native samples of one metric in a time range (scalar rows, plus per-day pieces of multi-day series clipped to `day`). */
function samples(metric: string, from: number, to: number): RawPoint[] {
  return all<RawPoint>(`SELECT s.start_ms, s.end_ms, s.native_value value, src.name source FROM hk_samples s
    JOIN hk_types t ON t.id=s.type_id JOIN hk_sources src ON src.id=s.source_id
    WHERE t.metric=? AND s.deleted_at IS NULL AND s.native_value IS NOT NULL AND s.end_ms>=? AND s.start_ms<=?`, metric, from, to);
}
function dayPieces(metric: string, day: string): RawPoint[] {
  return all<RawPoint>(`SELECT s.start_ms, s.end_ms, v.total value, src.name source FROM hk_value_days v
    JOIN hk_samples s ON s.id=v.sample_id JOIN hk_types t ON t.id=s.type_id JOIN hk_sources src ON src.id=s.source_id
    WHERE v.day=? AND t.metric=? AND s.deleted_at IS NULL`, day, metric);
}

function computeFeatures(day: string, night: Night | null, hrvDaily: Map<string, number>, rhrDaily: Map<string, number>): Features {
  const off = ownerOffsetMin(Date.parse(`${day}T12:00:00Z`));
  const dayStart = Date.parse(`${day}T00:00:00Z`) - off * 60_000, dayEnd = dayStart + 24 * HOUR;
  let hrv: number | null = null, basis: Features["hrv_basis"] = null;
  if (night?.sleep_start && night.sleep_end) {
    const from = Date.parse(night.sleep_start) - 30 * 60_000, to = Date.parse(night.sleep_end) + 30 * 60_000;
    const pts = samples("hrv", from, to).filter((p) => p.start_ms >= from && p.start_ms <= to);
    if (pts.length) {
      const src = pickSource(pts.map((p) => p.source)), xs = pts.filter((p) => p.source === src).map((p) => p.value);
      hrv = xs.reduce((a, b) => a + b, 0) / xs.length; basis = "overnight";
    }
  }
  if (hrv === null && hrvDaily.has(day)) { hrv = hrvDaily.get(day)!; basis = "daily"; }
  const curve = (metric: string) => {
    const clip = (p: RawPoint) => ({ ...p, start_ms: Math.max(p.start_ms, dayStart), end_ms: Math.min(p.end_ms, dayEnd) });
    return curveFromSamples([...samples(metric, dayStart, dayEnd - 1), ...dayPieces(metric, day).map(clip)], day, off);
  };
  return {
    day, asleep_h: night?.asleep_h ?? null, bedtime_min: night?.sleep_start ? eveningMinutes(night.sleep_start) : null,
    bed_h: night ? bedHours(night) : null, wakeups: night?.wakeups ?? null, awake_min: night?.awake_h != null ? night.awake_h * 60 : null,
    hrv_ms: hrv, hrv_basis: basis, rhr_bpm: rhrDaily.get(day) ?? null,
    steps_curve: curve("steps"), kcal_curve: curve("active_kcal"),
  };
}

const rowToFeatures = (r: DerivedRow): Features => ({ day: r.day, asleep_h: r.asleep_h, bedtime_min: r.bedtime_min, bed_h: r.bed_h,
  wakeups: r.wakeups, awake_min: r.awake_min, hrv_ms: r.hrv_ms, hrv_basis: r.hrv_basis, rhr_bpm: r.rhr_bpm,
  steps_curve: r.steps_curve ? JSON.parse(r.steps_curve) : null, kcal_curve: r.kcal_curve ? JSON.parse(r.kcal_curve) : null });

/** Features for every day in [from, to] (to ≤ today), computing and caching the missing or stale ones in one pass. */
export function featuresRange(from: string, to: string): Map<string, Features> {
  const version = dataVersions().data;
  const rows = new Map(all<DerivedRow>("SELECT * FROM daily_derived WHERE day BETWEEN ? AND ?", from, to).map((r) => [r.day, r]));
  const out = new Map<string, Features>(), todo: string[] = [];
  for (let d = from; d <= to; d = addDays(d, 1)) {
    const r = rows.get(d);
    if (r && r.features_stale === 0 && r.features_at !== null) out.set(d, rowToFeatures(r)); else todo.push(d);
  }
  if (!todo.length) return out;
  const a = todo[0], z = todo.at(-1)!;
  const ns = new Map(nights(a, z).map((n) => [n.day, n])), hrv = daily("hrv", a, z), rhr = daily("resting_hr", a, z);
  const fresh = todo.map((d) => computeFeatures(d, ns.get(d) ?? null, hrv, rhr));
  for (const f of fresh) out.set(f.day, f);
  const at = Date.now();
  cacheWrite(version, () => {
    for (const f of fresh) run(`INSERT INTO daily_derived(day,asleep_h,bedtime_min,bed_h,wakeups,awake_min,hrv_ms,hrv_basis,rhr_bpm,steps_curve,kcal_curve,features_at,features_stale)
      VALUES(?,?,?,?,?,?,?,?,?,?,?,?,0) ON CONFLICT(day) DO UPDATE SET asleep_h=excluded.asleep_h,bedtime_min=excluded.bedtime_min,bed_h=excluded.bed_h,
      wakeups=excluded.wakeups,awake_min=excluded.awake_min,hrv_ms=excluded.hrv_ms,hrv_basis=excluded.hrv_basis,rhr_bpm=excluded.rhr_bpm,
      steps_curve=excluded.steps_curve,kcal_curve=excluded.kcal_curve,features_at=excluded.features_at,features_stale=0`,
      f.day, f.asleep_h, f.bedtime_min, f.bed_h, f.wakeups, f.awake_min, f.hrv_ms, f.hrv_basis, f.rhr_bpm,
      f.steps_curve && JSON.stringify(f.steps_curve), f.kcal_curve && JSON.stringify(f.kcal_curve), at);
  });
  return out;
}
export const features = (day: string) => featuresRange(day, day).get(day)!;

const nums = (fs: Features[], k: "asleep_h" | "bedtime_min" | "hrv_ms" | "rhr_bpm") => fs.map((f) => f[k]).filter((v): v is number => v !== null);

/** Sleep and recovery for one wake day. Cached for days ≤ today − 2 until something in their 60-day window changes. */
export function scoresFor(day: string, at = Date.now()) {
  const version = dataVersions().data;
  const t = todayOf(at), cacheable = day <= addDays(t, -2);
  if (cacheable) {
    const r = one<DerivedRow>("SELECT sleep_json,recovery_json,scores_stale FROM daily_derived WHERE day=?", day);
    if (r && r.scores_stale === 0 && r.sleep_json && r.recovery_json) return { day, sleep: JSON.parse(r.sleep_json), recovery: JSON.parse(r.recovery_json) } as Scores;
  }
  const feats = featuresRange(addDays(day, -BASELINE_DAYS), day);
  const window = [...feats.values()].filter((f) => f.day < day), f = feats.get(day)!;
  const night = nights(day, day)[0] ?? null;
  const target = storedTarget<number>("sleep_need_h");
  const need = sleepNeed({ target, asleepHistory: nums(window, "asleep_h") });
  let sleep: SleepScore | null = null;
  if (night) {
    const credit = napCreditH(addDays(day, -1), night.sleep_start ? { day, before: night.sleep_start } : null), need_h = need.need_h - credit;
    const parts = sleepParts({ asleep_h: night.asleep_h, need_h, bedtime_min: f.bedtime_min, bedtimeHistory: nums(window, "bedtime_min"),
      bed_h: f.bed_h, wakeups: f.wakeups, awake_min: f.awake_min });
    sleep = { ...sleepScore(parts), parts, need_h, need_basis: need.basis, nap_credit_h: credit };
  }
  const hrv = hrvPart(f.hrv_ms, nums(window, "hrv_ms")), rhr = rhrPart(f.rhr_bpm, nums(window, "rhr_bpm"));
  const rec = recoveryScore({ sleep: sleep?.score ?? null, hrv, rhr });
  const history = Math.max(nums(window, "hrv_ms").length, nums(window, "rhr_bpm").length);
  const reason = rec.status === "missing" ? (!night ? "No sleep recorded for last night" : "No heart data for last night") : rec.reason;
  const recovery = { score: rec.score, band: rec.band, label: rec.label, status: rec.status, reason, nights_of_history: history,
    nights_needed: rec.status === "calibrating" ? rec.nights_needed : Math.max(0, MIN_SCORE_DAYS - history),
    parts: { sleep: { score: sleep?.score ?? null, band: sleep?.band ?? null }, hrv: { ...hrv, unit: "ms", basis: f.hrv_basis }, resting_hr: { ...rhr, unit: "bpm" } } };
  if (cacheable) cacheWrite(version, () => run(`UPDATE daily_derived SET sleep_json=?,recovery_json=?,scores_at=?,scores_stale=0 WHERE day=?`,
    JSON.stringify(sleep), JSON.stringify(recovery), Date.now(), day));
  return { day, sleep, recovery } as Scores;
}
type SleepScore = ReturnType<typeof sleepScore> & { parts: ReturnType<typeof sleepParts>; need_h: number; need_basis: string; nap_credit_h: number };
export type Scores = { day: string; sleep: SleepScore | null; recovery: { score: number | null; band: string | null; label: string | null; status: string;
  reason: string | null; nights_of_history: number; nights_needed: number; parts: Record<string, Record<string, unknown>> } };

/** Sleep need for a wake day: the target, else the 90th-percentile rule over the 60 nights before it (11 §3.1). */
export function needFor(day: string, ignoreTarget = false) {
  const asleep = nights(addDays(day, -BASELINE_DAYS), addDays(day, -1)).map((n) => n.asleep_h);
  return sleepNeed({ target: ignoreTarget ? null : storedTarget<number>("sleep_need_h"), asleepHistory: asleep });
}

/** Wake time and bed-by for the night after `day` (11 §9.2): target, else median wake of the last 14 nights. */
export function tonightFor(day: string) {
  const wakes = nights(addDays(day, -13), day).filter((n) => n.sleep_end).map((n) => Number(n.sleep_end!.slice(11, 13)) * 60 + Number(n.sleep_end!.slice(14, 16)));
  return tonight({ wakeTarget: storedTarget<string>("wake_time"), wakeHistoryMin: wakes, need_h: needFor(day).need_h - napCreditH(day, { day: addDays(day, 1), before: null }) });
}

/**
 * Hours of nap that shorten a night's need: every nap on sleep day `prev`, plus naps on `also.day` that ended before
 * `also.before` (an evening nap before a 02:00 night). Per source, the largest; capped at SLEEP.NAP_CREDIT_MAX_H.
 */
export function napCreditH(prev: string, also: { day: string; before: string | null } | null): number {
  const bySource = new Map<string, number>();
  for (const n of naps(prev, also?.day ?? prev)) {
    if (n.day !== prev && also && also.before !== null && Date.parse(n.end) > Date.parse(also.before)) continue;
    bySource.set(n.source, (bySource.get(n.source) ?? 0) + n.asleep_h);
  }
  return Math.min(Math.max(0, ...bySource.values()), SLEEP.NAP_CREDIT_MAX_H);
}

/** Weight trend per day over [from, to], seeded from up to 120 days before `from` (11 §8.1). */
export function weightSeries(from: string, to: string) {
  const seedFrom = addDays(from, -120), w = daily("weight_kg", seedFrom, to);
  const days: { day: string; kg: number | null }[] = [];
  for (let d = seedFrom; d <= to; d = addDays(d, 1)) days.push({ day: d, kg: w.get(d) ?? null });
  return weightTrend(days, null).filter((p) => p.day >= from);
}
export const trendOn = (day: string) => weightSeries(day, day)[0]?.trend_kg ?? null;

type KcalRow = { week_start: string; kcal: number; mode: "initial" | "adaptive" | "fixed" | "kept"; tdee: number | null; intake_mean: number | null;
  slope_kg_day: number | null; rate_kg_week: number | null; intake_days: number | null; weigh_ins: number | null; reason: string | null; computed_at: number };

/** Daily logged kcal (Vitalis entries only, 11 §8.2) for [from, to]. */
export function intakeByDay(from: string, to: string) {
  return new Map(all<{ day: string; kcal: number }>("SELECT day, SUM(kcal) kcal FROM food_entries WHERE deleted_at IS NULL AND day BETWEEN ? AND ? GROUP BY day", from, to)
    .map((r) => [r.day, r.kcal]));
}

/**
 * This week's calorie target row, computed lazily on the first read of the week (or when `inTx`, a targets write, forces it).
 * An `initial` row follows the weight trend until a later week adapts, so a target read before the first weigh-in isn't frozen.
 */
/** Watch-measured daily burn over the `burn_window_days` before `day` (11 §8.2), or null. Two daily reads. */
export function burnBefore(day: string): number | null {
  const from = addDays(day, -FUEL.burn_window_days), to = addDays(day, -1);
  return measuredBurn(daily("resting_kcal", from, to), daily("active_kcal", from, to));
}

export function kcalTargetFor(weekStart: string, inTx = false): KcalRow {
  const existing = one<KcalRow>("SELECT * FROM kcal_targets WHERE week_start=?", weekStart);
  // Initial rows are re-derived on read: weight and goal changes move them until the first adaptive week.
  if (existing && !inTx && existing.mode !== "initial") return existing;
  const yesterday = addDays(weekStart, -1);
  const trend = trendOn(yesterday);
  const mode = storedTarget<string>("kcal_mode") ?? "adaptive";
  let row: Omit<KcalRow, "week_start" | "computed_at"> = { kcal: 0, mode: "initial", tdee: null, intake_mean: null, slope_kg_day: null, rate_kg_week: null, intake_days: null, weigh_ins: null, reason: null };
  const blank = { tdee: null, intake_mean: null, slope_kg_day: null, rate_kg_week: null, intake_days: null, weigh_ins: null, reason: null };
  const prev = one<KcalRow>("SELECT * FROM kcal_targets WHERE week_start<? ORDER BY week_start DESC LIMIT 1", weekStart);
  const goalKg = storedTarget<number>("goal_weight_kg"), direction = storedTarget<Goal>("goal");
  const rate = trend === null ? 0 : goalRate(goalKg, trend, direction), burn = burnBefore(weekStart);
  if (mode === "fixed") row = { ...blank, kcal: storedTarget<number>("kcal") ?? initialKcal(trend, rate, burn), mode: "fixed" };
  else if (prev) {
    const winStart = addDays(yesterday, -20), intake = intakeByDay(winStart, yesterday), w = daily("weight_kg", winStart, yesterday);
    const days = Array.from({ length: 21 }, (_, i) => addDays(winStart, i));
    const a = adaptiveKcal({ intakes: days.map((d) => intake.get(d) ?? null), weights: days.map((d) => w.get(d) ?? null),
      seed: trendOn(addDays(winStart, -1)), prev: prev.kcal, goal: goalKg, direction });
    row = { kcal: a.kcal, mode: a.mode, tdee: a.tdee, intake_mean: a.intake_mean, slope_kg_day: a.slope_kg_day, rate_kg_week: a.rate_kg_week,
      intake_days: a.intake_days, weigh_ins: a.weigh_ins, reason: a.reason };
  }
  // Until one week has really adapted, the goal-aware estimate stands, so a goal change shows up at once.
  const adapted = mode !== "fixed" && (row.mode === "adaptive" || !!one("SELECT 1 FROM kcal_targets WHERE week_start<? AND mode='adaptive'", weekStart));
  if (mode !== "fixed" && !adapted)
    row = { ...blank, kcal: initialKcal(trend, rate, burn), mode: "initial", rate_kg_week: roundHalfAway(rate, 3),
      tdee: burn === null ? null : roundHalfAway(burn),
      intake_days: row.intake_days, weigh_ins: row.weigh_ins, reason: prev ? row.reason : null };
  if (existing && !inTx && existing.mode === row.mode && existing.kcal === row.kcal) return existing;
  const full: KcalRow = { week_start: weekStart, ...row, computed_at: Date.now() };
  const write = () => run(`INSERT INTO kcal_targets(week_start,kcal,mode,tdee,intake_mean,slope_kg_day,rate_kg_week,intake_days,weigh_ins,reason,computed_at)
    VALUES(?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(week_start) DO UPDATE SET kcal=excluded.kcal,mode=excluded.mode,tdee=excluded.tdee,
    intake_mean=excluded.intake_mean,slope_kg_day=excluded.slope_kg_day,rate_kg_week=excluded.rate_kg_week,intake_days=excluded.intake_days,
    weigh_ins=excluded.weigh_ins,reason=excluded.reason,computed_at=excluded.computed_at`, full.week_start, full.kcal, full.mode, full.tdee,
    full.intake_mean, full.slope_kg_day, full.rate_kg_week, full.intake_days, full.weigh_ins, full.reason, full.computed_at);
  if (inTx) write(); else cacheWrite(dataVersions().data, write);
  return full;
}

type SetRow = { session_id: string; exercise_id: string; kind: TrainingSet["kind"]; performed_at: number; tz_offset_min: number;
  weight_kg: number | null; reps: number | null };
const withMuscles = (r: SetRow): TrainingSet => {
  const ex = getExercise(r.exercise_id);
  return { ...r, primary: ex?.primary ?? [], secondary: ex?.secondary ?? [] };
};
/** Working sets in [fromMs, toMs] with their exercise's muscles. */
export function trainingSets(fromMs: number, toMs: number): TrainingSet[] {
  return all<SetRow>(`SELECT t.session_id, t.exercise_id, t.kind, t.performed_at, s.tz_offset_min, t.weight_kg, t.reps FROM sets t
    JOIN sessions s ON s.id=t.session_id WHERE t.deleted_at IS NULL AND s.deleted_at IS NULL AND t.kind!='warmup' AND t.performed_at BETWEEN ? AND ?`,
    fromMs, toMs).map(withMuscles);
}

const sessionExercises = (id: string) =>
  [...new Set(all<{ exercise_id: string }>("SELECT exercise_id FROM sets WHERE session_id=? AND deleted_at IS NULL ORDER BY performed_at, ord", id).map((r) => r.exercise_id))];
const GENERIC = new Set(["", "workout", "strength", "traditional strength training"]);

/**
 * §7.2 splits: Settings splits in their order, then every other workout name logged in the last 90 days (by name).
 * A defined split's exercises come from its latest session (by split id or name); a history split's muscles from its latest session.
 */
export function splitCandidates(at = Date.now()): SplitCandidate[] {
  const latest = (where: string, ...args: string[]) => one<{ id: string }>(`SELECT s.id FROM sessions s WHERE s.deleted_at IS NULL AND ${where}
    AND EXISTS (SELECT 1 FROM sets x WHERE x.session_id=s.id AND x.deleted_at IS NULL AND x.kind!='warmup') AND s.started_at<=? ORDER BY s.started_at DESC LIMIT 1`, ...args, at);
  const defined: SplitCandidate[] = all<{ id: string; name: string; muscles: string }>("SELECT id,name,muscles FROM splits WHERE deleted_at IS NULL ORDER BY ord, created_at")
    .map((r) => {
      const s = latest("(s.template=? OR lower(trim(s.title))=lower(?))", r.id, r.name.trim());
      return { id: r.id, name: r.name, source: "defined", muscles: JSON.parse(r.muscles), exercises: s ? sessionExercises(s.id) : [] };
    });
  const taken = new Set(defined.map((d) => d.name.trim().toLowerCase()));
  const names = all<{ name: string }>(`SELECT trim(s.title) name FROM sessions s WHERE s.deleted_at IS NULL AND s.title IS NOT NULL AND s.started_at BETWEEN ? AND ?
    AND EXISTS (SELECT 1 FROM sets x WHERE x.session_id=s.id AND x.deleted_at IS NULL AND x.kind!='warmup')
    GROUP BY lower(trim(s.title)) ORDER BY lower(trim(s.title))`, at - TRAINING.splitHistoryDays * 24 * HOUR, at);
  const history: SplitCandidate[] = names.filter((n) => !GENERIC.has(n.name.toLowerCase()) && !taken.has(n.name.toLowerCase())).flatMap((n) => {
    const s = latest("lower(trim(s.title))=lower(?)", n.name);
    if (!s) return [];
    const sets = all<SetRow>(`SELECT t.session_id, t.exercise_id, t.kind, t.performed_at, s.tz_offset_min, t.weight_kg, t.reps FROM sets t
      JOIN sessions s ON s.id=t.session_id WHERE t.session_id=? AND t.deleted_at IS NULL ORDER BY t.performed_at, t.ord`, s.id).map(withMuscles);
    return [{ id: `history:${n.name.toLowerCase()}`, name: n.name, source: "history" as const, muscles: sessionMuscles(sets), exercises: sessionExercises(s.id) }];
  });
  return [...defined, ...history];
}

/** Freshness, heat, splits and labels as of `at` (11 §7). Not cached: a few hundred rows. */
export function trainingState(at = Date.now()) {
  const t = localDay(at, ownerOffsetMin(at));
  const recent = trainingSets(at - 30 * 24 * HOUR, at);
  // days_since needs each exercise's latest working set ever, not only the last 30 days.
  const latest = all<SetRow>(`SELECT t.session_id, t.exercise_id, t.kind, MAX(t.performed_at) performed_at, s.tz_offset_min, t.weight_kg, t.reps
    FROM sets t JOIN sessions s ON s.id=t.session_id WHERE t.deleted_at IS NULL AND s.deleted_at IS NULL AND t.kind!='warmup' AND t.performed_at<=?
    GROUP BY t.exercise_id`, at).map(withMuscles);
  const fresh = freshness([...recent, ...latest], at, t);
  const splits = splitStates(splitCandidates(at), fresh);
  const heat = Object.fromEntries(SLUGS.map((m) => [m, fresh[m].heat]));
  const trainedToday = !!one("SELECT 1 FROM sessions s WHERE s.deleted_at IS NULL AND EXISTS (SELECT 1 FROM sets x WHERE x.session_id=s.id AND x.deleted_at IS NULL) AND s.started_at BETWEEN ? AND ?",
    Date.parse(`${t}T00:00:00Z`) - ownerOffsetMin(at) * 60_000, Date.parse(`${t}T00:00:00Z`) - ownerOffsetMin(at) * 60_000 + 24 * HOUR - 1);
  return { fresh, heat, splits: splits.map((r) => ({ ...r, exercises: r.exercises.map((id) => ({ id, name: getExercise(id)?.name ?? id })) })),
    fresh_label: freshLabel(splits), loaded_label: loadedLabel(fresh), trained_today: trainedToday };
}
