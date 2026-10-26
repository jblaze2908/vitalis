// Train tab, session history and session detail bodies (spec 10 §6). PRs use the same rule as trainingSummary: a session's
// best estimated 1RM for an exercise above every earlier best for it; the first time an exercise is logged is not a PR.
import { all, one } from "./db.js";
import { trainingState, trainingSets } from "./derived.js";
import { getExercise } from "./exercises.js";
import { freshnessBlock } from "./health.js";
import { ApiError } from "./http.js";
import { effectiveTargets } from "./targets.js";
import { addDays, isoAt, ownerOffsetMin, today } from "./time.js";
import { e1rm, LIVE_HK, liveSets, listWorkouts, sessionView, type SessionRow, type SetRow } from "./training.js";
import { SLUGS, sessionHeat, weekStartOf, weeklySets, type TrainingSet } from "./training-analytics.js";
import { dateLabel } from "./today.js";
import { workoutHeart } from "./heart.js";

const MON = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"];
const dm = (day: string) => `${Number(day.slice(8))} ${MON[Number(day.slice(5, 7)) - 1]}`;
const localMs = (day: string, off: number) => Date.parse(`${day}T00:00:00Z`) - off * 60_000;

export type SessionPR = { exercise_id: string; exercise: string; set: string; e1rm_kg_estimate: number; previous_best_estimate: number | null; first_time: boolean };
/** Per exercise in one session: its best working e1RM against every earlier working set of that exercise. */
export function sessionPRs(sessionId: string): SessionPR[] {
  const rows = all<{ exercise_id: string; weight_kg: number; reps: number; performed_at: number; prior: number | null }>(`
    SELECT t.exercise_id, t.weight_kg, t.reps, t.performed_at,
      (SELECT MAX(CASE WHEN p.reps = 1 THEN p.weight_kg ELSE p.weight_kg * (1 + p.reps / 30.0) END) FROM sets p JOIN sessions ps ON ps.id=p.session_id
        WHERE p.exercise_id=t.exercise_id AND p.session_id<>t.session_id AND p.performed_at < (SELECT MIN(performed_at) FROM sets WHERE session_id=t.session_id AND deleted_at IS NULL)
        AND p.deleted_at IS NULL AND ps.deleted_at IS NULL AND p.kind!='warmup' AND p.reps BETWEEN 1 AND 12 AND p.weight_kg > 0) prior
    FROM sets t WHERE t.session_id=? AND t.deleted_at IS NULL AND t.kind!='warmup' AND t.reps BETWEEN 1 AND 12 AND t.weight_kg > 0`, sessionId);
  const best = new Map<string, { e: number; set: string; prior: number | null }>();
  for (const r of rows) {
    const e = e1rm(r.weight_kg, r.reps)!;
    if (!best.has(r.exercise_id) || e > best.get(r.exercise_id)!.e) best.set(r.exercise_id, { e, set: `${r.weight_kg} kg × ${r.reps}`, prior: r.prior === null ? null : Math.round(r.prior * 10) / 10 });
  }
  return [...best].map(([id, v]) => ({ exercise_id: id, exercise: getExercise(id)?.name ?? id, set: v.set, e1rm_kg_estimate: v.e,
    previous_best_estimate: v.prior, first_time: v.prior === null }));
}
const prs = (sessionId: string) => sessionPRs(sessionId).filter((p) => !p.first_time && p.e1rm_kg_estimate > p.previous_best_estimate!);
const shortName = (id: string) => {
  const ex = getExercise(id);
  return (ex?.aliases[0] ?? ex?.name ?? id).toUpperCase();
};

type Listed = ReturnType<typeof listWorkouts>[number];
/** One row of the Train tab and history list. */
function sessionRow(w: Listed) {
  const visit = "parts" in w && w.parts ? { part_count: w.parts.length, parts: w.parts.map((p) => p.title) } : {};
  if (w.type === "strength") {
    const v = w as ReturnType<typeof sessionView> & { hr_avg?: number | null }, pr = prs(v.id)[0];
    const hr = v.hr_avg ?? (typeof v.watch === "object" ? v.watch.hr_avg : null);
    return { id: v.id, kind: "strength", title: v.title ?? "Workout", day: v.day, start: v.start, duration_min: v.duration_min, working_sets: v.working_sets,
      hr_avg: hr ?? null, ...visit, tag: pr ? { kind: "pr", label: `PR · ${shortName(pr.exercise_id)}` } : null };
  }
  const c = w as Listed & { hr_avg: number | null };
  return { id: c.id, kind: "cardio", title: c.title, day: c.day, start: c.start, duration_min: c.duration_min, hr_avg: c.hr_avg ?? null, ...visit,
    tag: { kind: "cardio", label: "CARDIO" } };
}

const toTraining = (r: SetRow & { tz_offset_min: number }): TrainingSet => {
  const ex = getExercise(r.exercise_id);
  return { ...r, primary: ex?.primary ?? [], secondary: ex?.secondary ?? [] };
};

export function trainingWeek(dayInWeek: string, at = Date.now()) {
  const t = today(at), weekStart = weekStartOf(dayInWeek), weekEnd = addDays(weekStart, 6), off = ownerOffsetMin(at);
  const stateAt = Math.min(at, localMs(addDays(weekEnd, 1), off) - 1);
  const state = trainingState(stateAt), targets = effectiveTargets(at);
  const weekSets = trainingSets(localMs(weekStart, off) - 14 * 3_600_000, localMs(addDays(weekEnd, 1), off) + 14 * 3_600_000);
  const ws = weeklySets(weekSets, weekStart, { min: targets.weekly_sets_min, max: targets.weekly_sets_max });
  const list = listWorkouts(weekStart, weekEnd);
  const strength = list.filter((w) => w.type === "strength") as ReturnType<typeof sessionView>[];
  const lastSet = (id: string) => one<{ weight_kg: number | null; reps: number | null; performed_at: number; tz_offset_min: number }>(`SELECT t.weight_kg, t.reps, t.performed_at, s.tz_offset_min
    FROM sets t JOIN sessions s ON s.id=t.session_id WHERE t.exercise_id=? AND t.deleted_at IS NULL AND s.deleted_at IS NULL AND t.kind!='warmup'
    ORDER BY t.performed_at DESC, t.weight_kg DESC LIMIT 1`, id);
  const label = weekStart === weekStartOf(t) ? "THIS WEEK" : weekStart === weekStartOf(addDays(t, -7)) ? "LAST WEEK" : "WEEK";
  return {
    week_start: weekStart, week_end: weekEnd, label: `${label} · ${dm(weekStart).split(" ")[0]} TO ${dm(weekEnd)}`,
    heat: state.heat,
    muscles: SLUGS.map((m) => ({ slug: m, heat: state.fresh[m].heat, load: state.fresh[m].load, days_since: state.fresh[m].days_since,
      week_sets: ws.by_muscle[m], status: ws.status[m] })),
    // `due` stays null for apps built before `ready` (11 §7.3: nothing is picked for the owner).
    due: null,
    splits: state.splits.map((r) => ({ id: r.id, name: r.name, source: r.source, ready: r.ready, days_since: r.days_since, muscles: r.muscles,
      exercise_count: r.exercises.length, exercises: r.exercises.map((e) => {
        const l = lastSet(e.id);
        return { ...e, last: l ? { weight_kg: l.weight_kg, reps: l.reps, day: isoAt(l.performed_at, l.tz_offset_min).slice(0, 10) } : null };
      }) })),
    stats: { sessions: strength.length, working_sets: strength.reduce((n, s) => n + s.working_sets, 0), muscles_hit: ws.muscles_hit, muscles_total: ws.muscles_total },
    weekly_sets: { min: ws.min, max: ws.max, by_muscle: ws.by_muscle },
    sessions: list.map(sessionRow),
    // Apple Watch workouts count: the empty state has no history list, so it must never hide one.
    empty: !one("SELECT 1 FROM sessions s WHERE s.deleted_at IS NULL AND EXISTS (SELECT 1 FROM sets x WHERE x.session_id=s.id AND x.deleted_at IS NULL)")
      && !one(`SELECT 1 FROM hk_workouts w WHERE ${LIVE_HK} LIMIT 1`),
    freshness: freshnessBlock(at),
  };
}

const encodeCursor = (ms: number, id: string) => Buffer.from(`${ms}:${id}`).toString("base64url");
function decodeCursor(c: string) {
  const m = /^(\d+):(.+)$/.exec(Buffer.from(c, "base64url").toString("utf8"));
  if (!m) throw new ApiError(400, "before is not a cursor from this server", "bad_request");
  return { ms: Number(m[1]), id: m[2] };
}

/** Newest-first history, strength and unattached Watch workouts merged exactly as on the Train tab. */
export function sessionHistory(before: string | undefined, limit: number, at = Date.now()) {
  const cur = before ? decodeCursor(before) : null;
  const firstMs = Math.min(one<{ m: number | null }>("SELECT MIN(started_at) m FROM sessions WHERE deleted_at IS NULL")?.m ?? Infinity,
    one<{ m: number | null }>("SELECT MIN(start_ms) m FROM hk_workouts")?.m ?? Infinity);
  const off = ownerOffsetMin(at), endDay = cur ? isoAt(cur.ms, off).slice(0, 10) : today(at);
  const after = (r: { start: string; id: string }) => !cur || Date.parse(r.start) < cur.ms || (Date.parse(r.start) === cur.ms && r.id < cur.id);
  let rows: ReturnType<typeof sessionRow>[] = [];
  for (let span = 30; ; span *= 2) {
    const from = addDays(endDay, -span);
    rows = listWorkouts(from, addDays(endDay, 1)).map(sessionRow).filter(after)
      .sort((a, b) => Date.parse(b.start) - Date.parse(a.start) || b.id.localeCompare(a.id));
    if (rows.length > limit || !Number.isFinite(firstMs) || localMs(from, off) <= firstMs || span > 20000) break;
  }
  const page = rows.slice(0, limit), last = page.at(-1);
  return { sessions: page, next: rows.length > limit && last ? encodeCursor(Date.parse(last.start), last.id) : null, freshness: freshnessBlock(at) };
}

const MONTH_DAY = (iso: string) => `${dateLabel(iso.slice(0, 10))} · ${iso.slice(11, 16)}`;

/** One workout, or the whole visit when it was back-to-back with others: any member's id opens the visit. */
export function sessionDetail(id: string, at = Date.now()) {
  const s = one<{ started_at: number; tz_offset_min: number }>("SELECT started_at,tz_offset_min FROM sessions WHERE id=? AND deleted_at IS NULL", id);
  const day = s ? isoAt(s.started_at, s.tz_offset_min).slice(0, 10) : one<{ day: string }>("SELECT day FROM hk_workouts WHERE id=?", id)?.day;
  type Visit = Listed & { hr_avg?: number | null; hr_max?: number | null; active_kcal_estimate?: number | null; distance_km?: number };
  const visit = (day ? listWorkouts(addDays(day, -1), addDays(day, 1)).find((w) => w.parts?.some((p) => p.id === id)) : undefined) as Visit | undefined;
  if (!visit?.parts) return singleDetail(id, at);
  const base = singleDetail(visit.id, at), startMs = Date.parse(visit.start), endMs = Math.min(at, Date.parse(visit.end));
  const ids = visit.parts.map((p) => p.id);
  const src = one<{ source: string }>(`SELECT source FROM hk_workouts WHERE source IS NOT NULL AND id IN (${ids.map(() => "?").join(",")}) LIMIT 1`, ...ids)?.source ?? null;
  const hr = workoutHeart(startMs, endMs, src);
  return { ...base, title: visit.title, start: visit.start, end: visit.end, duration_min: visit.duration_min,
    context_label: `${MONTH_DAY(visit.start)} · ${visit.duration_min} MIN`,
    ...(base.kind === "cardio" ? { name: null, duration_s: (endMs - startMs) / 1000, hr_avg: visit.hr_avg, hr_max: visit.hr_max, distance_km: visit.distance_km ?? null }
      : { avg_bpm: hr?.avg ?? visit.hr_avg }),
    active_kcal: visit.active_kcal_estimate, parts: visit.parts, hr: hr && { ...hr, start: visit.start } };
}

function singleDetail(id: string, at: number) {
  const s = one<SessionRow>("SELECT * FROM sessions WHERE id=?", id);
  if (!s) {
    const w = one<Record<string, unknown> & { start_ms: number; end_ms: number; source: string | null }>(
      "SELECT id,name,start,end,start_ms,end_ms,day,duration_s,active_kcal,hr_min,hr_avg,hr_max,distance_km,source FROM hk_workouts WHERE id=?", id);
    if (!w) throw new ApiError(404, `No workout ${id}`);
    const { start_ms, end_ms, ...rest } = w;
    return { ...rest, kind: "cardio", hr: workoutHeart(start_ms, end_ms, w.source), freshness: freshnessBlock(at) };
  }
  if (s.deleted_at) throw new ApiError(404, `Workout ${id} was deleted`);
  const sets = liveSets([s.id]), v = sessionView(s, sets, true);
  const pr = new Set(prs(s.id).map((p) => p.exercise_id));
  const heat = sessionHeat(sets.map((x) => toTraining({ ...x, tz_offset_min: s.tz_offset_min })));
  const watch = typeof v.watch === "object" ? v.watch : null;
  const hk = watch ? one<{ start_ms: number; end_ms: number; source: string | null }>("SELECT start_ms,end_ms,source FROM hk_workouts WHERE id=?", watch.workout_id) : null;
  const hr = hk ? workoutHeart(hk.start_ms, hk.end_ms, hk.source) : workoutHeart(Date.parse(v.start), Math.min(at, Date.parse(v.end)), null);
  return {
    id: s.id, kind: "strength", title: s.title ?? "Workout", template: s.template ?? null, client_source: s.client_source ?? null,
    start: v.start, end: v.end, duration_min: v.duration_min, context_label: `${MONTH_DAY(v.start)} · ${v.duration_min} MIN`,
    working_sets: v.working_sets, volume_kg: v.volume_kg, avg_bpm: watch?.hr_avg ?? null, active_kcal: watch?.active_kcal_estimate ?? null,
    heat,
    exercises: v.exercises.map((e) => {
      const xs = sets.filter((x) => x.exercise_id === e.exercise_id), w = xs.filter((x) => x.kind !== "warmup");
      const top = w.reduce<SetRow | null>((b, x) => (!b || (x.weight_kg ?? 0) > (b.weight_kg ?? 0) || ((x.weight_kg ?? 0) === (b.weight_kg ?? 0) && (x.reps ?? 0) > (b.reps ?? 0)) ? x : b), null);
      return { id: e.exercise_id, name: e.name, working_sets: w.length, top_set: top ? { weight_kg: top.weight_kg, reps: top.reps } : null,
        summary: `${w.length} SETS${top ? ` · TOP ${top.weight_kg ?? 0} X ${top.reps ?? "-"}` : ""}`, pr: pr.has(e.exercise_id),
        sets: xs.map((x) => ({ id: x.id, kind: x.kind, weight_kg: x.weight_kg, reps: x.reps, at: isoAt(x.performed_at, s.tz_offset_min) })) };
    }),
    watch: watch ? { workout_id: watch.workout_id, hr_avg: watch.hr_avg, hr_max: watch.hr_max } : null,
    // Set times are offsets from here, so the app can mark each set on the heart-rate line.
    hr: hr && { ...hr, start: hk ? isoAt(hk.start_ms, s.tz_offset_min) : v.start },
    freshness: freshnessBlock(at),
  };
}
