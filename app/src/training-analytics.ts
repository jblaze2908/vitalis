// Pure training analytics (spec/11-scoring.md §7). No SQL, no clock: `now` (epoch ms) and local days are arguments.
// Inputs carry muscle names as stored (spaces); every output is keyed by the 17 hyphen slugs.
import { MUSCLES } from "./exercises.js";
import { TRAINING, roundHalfAway } from "./scoring-config.js";
import { addDays, localDay } from "./time.js";
import type { Kind } from "./training.js";

export type TrainingSet = {
  session_id: string; exercise_id: string; kind: Kind; performed_at: number; tz_offset_min: number;
  weight_kg: number | null; reps: number | null; primary: string[]; secondary: string[];
};
export type Heat = 0 | 1 | 2 | 3 | 4;
export type MuscleFreshness = { heat: Heat; load: number; days_since: number | null };
export type Freshness = Record<string, MuscleFreshness>;
/** A split the owner can start: defined in Settings, or a workout name they have logged. Muscles are slugs. */
export type SplitCandidate = { id: string; name: string; source: "defined" | "history"; muscles: string[]; exercises: string[] };
export type SplitState = SplitCandidate & { ready: boolean; days_since: number | null };

export const toSlug = (muscle: string) => muscle.trim().toLowerCase().replace(/\s+/g, "-");
export const fromSlug = (slug: string) => slug.replace(/-/g, " ");
export const SLUGS: readonly string[] = MUSCLES.map(toSlug);

const HOUR = 3_600_000;
const DAY = 24 * HOUR;
const working = (s: TrainingSet) => s.kind !== "warmup";
const perMuscle = <T>(f: (slug: string) => T): Record<string, T> => Object.fromEntries(SLUGS.map((m) => [m, f(m)]));
const daysBetween = (from: string, to: string) => Math.round((Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`)) / DAY);

/** Weighted (primary 1, secondary 0.5) contribution of each working set; unknown muscle names are ignored. */
function weighted(sets: TrainingSet[], f: (s: TrainingSet, slug: string, w: number) => void) {
  const known = new Set(SLUGS);
  for (const s of sets) {
    if (!working(s)) continue;
    for (const m of s.primary) if (known.has(toSlug(m))) f(s, toSlug(m), TRAINING.weight.primary);
    for (const m of s.secondary) if (known.has(toSlug(m))) f(s, toSlug(m), TRAINING.weight.secondary);
  }
}

/** L = Σ w·exp(−Δh/τ) over working sets in (now − 14 d, now]. Unrounded. */
export function muscleLoad(sets: TrainingSet[], now: number): Record<string, number> {
  const L = perMuscle(() => 0);
  const from = now - TRAINING.loadWindowDays * DAY;
  weighted(sets, (s, m, w) => {
    if (s.performed_at > now || s.performed_at <= from) return;
    L[m] += w * Math.exp(-(now - s.performed_at) / HOUR / TRAINING.tauH);
  });
  return L;
}

export function heat(L: number, trainedIn30d: boolean): Heat {
  if (!trainedIn30d) return 0;
  const t = TRAINING.heat;
  return L < t.fresh ? 1 : L < t.recovering ? 2 : L < t.partly ? 3 : 4;
}

/**
 * Heat, load (2 dp, as the API shows it) and days_since for all 17 slugs as of `now`; `today` = owner's local day of `now`.
 * Caller passes every set in the 30 days before `now` plus each exercise's most recent working set ever (for days_since);
 * older or future sets are harmless because both windows are applied here.
 */
export function freshness(sets: TrainingSet[], now: number, today: string): Freshness {
  const L = muscleLoad(sets, now);
  const touched = new Set<string>();
  const lastPrimaryDay: Record<string, string> = {};
  const from30 = now - TRAINING.noDataWindowDays * DAY;
  weighted(sets, (s, m, w) => {
    if (s.performed_at > now) return;
    if (s.performed_at > from30) touched.add(m);
    if (w !== TRAINING.weight.primary) return;
    const d = localDay(s.performed_at, s.tz_offset_min);
    if (!lastPrimaryDay[m] || d > lastPrimaryDay[m]) lastPrimaryDay[m] = d;
  });
  return perMuscle((m) => ({
    heat: heat(L[m]!, touched.has(m)),
    load: roundHalfAway(L[m]!, 2),
    // A set's own offset can put its local day after `today`; that still counts as trained today.
    days_since: lastPrimaryDay[m] ? Math.max(0, daysBetween(lastPrimaryDay[m], today)) : null,
  }));
}

/**
 * §7.3: a split is ready when all its muscles have heat ≤ 1 (no muscles: always). Order is kept as given; nothing is ranked.
 */
export function splitStates(splits: SplitCandidate[], fresh: Freshness): SplitState[] {
  return splits.map((sp) => {
    const min = sp.muscles.length ? Math.min(...sp.muscles.map((m) => fresh[m]?.days_since ?? Infinity)) : Infinity;
    return { ...sp, ready: sp.muscles.every((m) => (fresh[m]?.heat ?? 0) <= 1), days_since: Number.isFinite(min) ? min : null };
  });
}

/** "Push fresh" for one ready split, "3 splits fresh" for more, else null. */
export const freshLabel = (splits: SplitState[]) => {
  const ready = splits.filter((s) => s.ready);
  return ready.length === 0 ? null : ready.length === 1 ? `${ready[0].name} fresh` : `${ready.length} splits fresh`;
};

/** Muscles a session trained: primary muscles of its working sets, as slugs, in first-seen order. */
export const sessionMuscles = (sets: TrainingSet[]) =>
  [...new Set(sets.filter(working).flatMap((s) => s.primary.map(toSlug)).filter((m) => SLUGS.includes(m)))];

/**
 * "<Muscle> loaded" for the hottest muscle with heat ≥ 3, else null. The "group" is the single muscle, display name =
 * stored name with a capital first letter ("Lower back"). Ties: higher load, then MUSCLES order.
 */
export function loadedLabel(fresh: Freshness): string | null {
  let top: string | null = null;
  for (const m of SLUGS) {
    const f = fresh[m];
    if (!f || f.heat < 3) continue;
    const t = top ? fresh[top]! : null;
    if (!t || f.heat > t.heat || (f.heat === t.heat && f.load > t.load)) top = m;
  }
  if (!top) return null;
  const name = fromSlug(top);
  return `${name[0]!.toUpperCase()}${name.slice(1)} loaded`;
}

/** §7.4 heat for one session's sets: weighted working sets ≥ 4 → 4, ≥ 2 → 3, > 0 → 2, else 0. */
export function sessionHeat(sets: TrainingSet[]): Record<string, 0 | 2 | 3 | 4> {
  const n = perMuscle(() => 0);
  weighted(sets, (_s, m, w) => { n[m] += w; });
  const t = TRAINING.sessionHeat;
  return perMuscle((m) => (n[m]! >= t.loaded ? 4 : n[m]! >= t.partly ? 3 : n[m]! > 0 ? 2 : 0));
}

/** Monday of the local week containing `day`. */
export function weekStartOf(day: string) {
  const dow = new Date(`${day}T00:00:00Z`).getUTCDay();
  return addDays(day, -((dow + 6) % 7));
}

export type WeeklyStatus = "under" | "in_range" | "over";

/** §7.5 over the local week starting `weekStart` (a Monday); a set's day uses its own tz offset. */
export function weeklySets(sets: TrainingSet[], weekStart: string, range: { min: number; max: number } = TRAINING.weeklySets) {
  const end = addDays(weekStart, 6);
  const n = perMuscle(() => 0);
  weighted(sets, (s, m, w) => {
    const d = localDay(s.performed_at, s.tz_offset_min);
    if (d >= weekStart && d <= end) n[m] += w;
  });
  const by_muscle = perMuscle((m) => roundHalfAway(n[m]! * 2) / 2);
  const status = perMuscle<WeeklyStatus>((m) => (by_muscle[m]! < range.min ? "under" : by_muscle[m]! > range.max ? "over" : "in_range"));
  return { week_start: weekStart, week_end: end, min: range.min, max: range.max, by_muscle, status,
    muscles_hit: SLUGS.filter((m) => by_muscle[m]! >= 1).length, muscles_total: SLUGS.length };
}

export type E1rmPoint = { day: string; kg: number; session_id: string };

/**
 * §7.6: points in the 84 local days ending `today` (one per session, best kept), oldest first.
 * change_8w_kg = last − first within the 56 days ending `today`, null with fewer than 2 points there.
 */
export function e1rmTrend(points: E1rmPoint[], today: string) {
  const { windowDays, changeDays } = TRAINING.e1rmTrend;
  const from = addDays(today, -windowDays);
  const bySession = new Map<string, E1rmPoint>();
  for (const p of points) {
    if (p.day <= from || p.day > today) continue;
    const prev = bySession.get(p.session_id);
    if (!prev || p.kg > prev.kg) bySession.set(p.session_id, p);
  }
  const kept = [...bySession.values()].sort((a, b) => (a.day < b.day ? -1 : a.day > b.day ? 1 : 0));
  const from8w = addDays(today, -changeDays);
  const recent = kept.filter((p) => p.day > from8w);
  return {
    current_kg: kept.at(-1)?.kg ?? null,
    change_8w_kg: recent.length >= 2 ? roundHalfAway(recent.at(-1)!.kg - recent[0]!.kg, 1) : null,
    points: kept,
    estimate: true as const,
  };
}
