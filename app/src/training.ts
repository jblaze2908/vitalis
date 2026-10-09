// Strength training: sessions of sets, written with client ids so a retry is a no-op. Warm-ups never count toward
// volume or records. Estimated 1RM is Epley (w × (1 + reps/30)), given only for 1–12 reps and always labelled an estimate.
import { randomUUID } from "node:crypto";
import { MAJOR_MUSCLES } from "./catalog.js";
import { httpErr, now } from "./config.js";
import { all, marks, one, run, tx } from "./db.js";
import { getExercise, resolveExercise, type Exercise } from "./exercises.js";
import { addDays, isoAt, localDay, ownerOffsetMin, parseStamp } from "./time.js";
import { round } from "./stats.js";

export const KINDS = ["warmup", "normal", "drop", "failure"] as const;
export type Kind = (typeof KINDS)[number];
export const SESSION_GAP_H = 3;

export type SetInput = { id?: string; exercise: string; kind?: Kind; weight_kg?: number | null; reps?: number | null; duration_s?: number | null;
  distance_m?: number | null; rpe?: number | null; rir?: number | null; target_weight_kg?: number | null; target_reps?: number | null;
  performed_at?: string; note?: string | null };
type SetRow = { id: string; session_id: string; exercise_id: string; ord: number; kind: Kind; weight_kg: number | null; reps: number | null;
  duration_s: number | null; distance_m: number | null; rpe: number | null; rir: number | null; target_weight_kg: number | null;
  target_reps: number | null; performed_at: number; note: string | null; deleted_at: number | null };
type SessionRow = { id: string; title: string | null; started_at: number; ended_at: number | null; tz_offset_min: number; notes: string | null;
  source: string; deleted_at: number | null };

export const e1rm = (w: number | null, r: number | null) => (w && r && r >= 1 && r <= 12 ? round(r === 1 ? w : w * (1 + r / 30), 1) : null);
const working = (s: { kind: Kind }) => s.kind !== "warmup";

function stampOrNow(s: string | undefined) {
  if (!s) return { ms: now(), offsetMin: ownerOffsetMin() };
  const t = parseStamp(s);
  if (!t) throw httpErr(400, `performed_at "${s}" isn't an ISO 8601 time like 2026-10-09T19:05:00+05:30`);
  if (t.ms > now() + 10 * 60_000) throw httpErr(400, "performed_at is in the future");
  return t;
}

export function logSets(input: { session_id?: string; title?: string; sets: SetInput[] }, source: string) {
  if (!input.sets.length) throw httpErr(400, "Send at least one set");
  const unclear: string[] = [];
  const resolved = input.sets.map((s) => {
    const r = resolveExercise(s.exercise);
    if ("candidates" in r) unclear.push(`"${s.exercise}": ${r.candidates.length ? `did you mean ${r.candidates.map((c) => `${c.name} (${c.id})`).join(", ")}?` : "no match; call find_exercises or create_exercise"}`);
    return "exercise" in r ? r.exercise : null;
  });
  if (unclear.length) throw httpErr(422, `Nothing logged. Use an exercise id for: ${unclear.join("; ")}`);
  const times = input.sets.map((s) => stampOrNow(s.performed_at));
  const first = times.reduce((a, b) => (b.ms < a.ms ? b : a));

  return tx(() => {
    const session = sessionFor(input.session_id, input.title, first, source);
    let ord = one<{ n: number | null }>("SELECT MAX(ord) n FROM sets WHERE session_id=?", session.id)!.n ?? 0;
    const logged: ReturnType<typeof setView>[] = [], already: string[] = [];
    input.sets.forEach((s, i) => {
      const id = s.id ?? randomUUID();
      const prior = one<SetRow>("SELECT * FROM sets WHERE id=?", id);
      if (prior) { if (prior.session_id !== session.id) throw httpErr(409, `Set ${id} already belongs to another session`); already.push(id); return; }
      checkSet(s);
      run(`INSERT INTO sets(id,session_id,exercise_id,ord,kind,weight_kg,reps,duration_s,distance_m,rpe,rir,target_weight_kg,target_reps,performed_at,note,created_at,updated_at)
           VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`, id, session.id, resolved[i]!.id, ++ord, s.kind ?? "normal", s.weight_kg ?? null, s.reps ?? null,
        s.duration_s ?? null, s.distance_m ?? null, s.rpe ?? null, s.rir ?? null, s.target_weight_kg ?? null, s.target_reps ?? null, times[i].ms, s.note ?? null, now(), now());
      logged.push(setView(one<SetRow>("SELECT * FROM sets WHERE id=?", id)!, session.tz_offset_min));
    });
    run("UPDATE sessions SET updated_at=? WHERE id=?", now(), session.id);
    return { session: { id: session.id, title: session.title, started: isoAt(session.started_at, session.tz_offset_min), created: session.created },
      logged, already_logged: already };
  });
}

function checkSet(s: SetInput) {
  if (s.kind && !KINDS.includes(s.kind)) throw httpErr(400, `kind is one of ${KINDS.join(", ")}`);
  if (s.weight_kg != null && (s.weight_kg < 0 || s.weight_kg > 1000)) throw httpErr(400, "weight_kg must be 0–1000");
  if (s.reps != null && (!Number.isInteger(s.reps) || s.reps < 0 || s.reps > 1000)) throw httpErr(400, "reps must be a whole number 0–1000");
  if (s.rpe != null && (s.rpe < 1 || s.rpe > 10)) throw httpErr(400, "rpe must be 1–10");
  if (s.reps == null && s.duration_s == null && s.distance_m == null) throw httpErr(400, "A set needs reps, duration_s or distance_m");
}

/** The session a set belongs to: the one named, else the latest whose last set is within SESSION_GAP_H hours, else a new one. */
function sessionFor(id: string | undefined, title: string | undefined, at: { ms: number; offsetMin: number }, source: string) {
  if (id) {
    const s = one<SessionRow>("SELECT * FROM sessions WHERE id=?", id);
    if (s?.deleted_at) throw httpErr(409, `Session ${id} was deleted; restore it with edit_workout first`);
    if (s) { if (title && title !== s.title) run("UPDATE sessions SET title=? WHERE id=?", title, id); return { ...s, title: title ?? s.title, created: false }; }
  } else {
    const recent = one<SessionRow & { last: number }>(`SELECT s.*, MAX(COALESCE(t.performed_at, s.started_at)) last FROM sessions s
      LEFT JOIN sets t ON t.session_id=s.id AND t.deleted_at IS NULL WHERE s.deleted_at IS NULL AND s.ended_at IS NULL
      GROUP BY s.id HAVING last BETWEEN ? AND ? ORDER BY last DESC LIMIT 1`, at.ms - SESSION_GAP_H * 3_600_000, at.ms + SESSION_GAP_H * 3_600_000);
    if (recent) { if (title && !recent.title) run("UPDATE sessions SET title=? WHERE id=?", title, recent.id); return { ...recent, title: recent.title ?? title ?? null, created: false }; }
  }
  const sid = id ?? randomUUID();
  run("INSERT INTO sessions(id,title,started_at,tz_offset_min,source,created_at,updated_at) VALUES(?,?,?,?,?,?,?)", sid, title ?? null, at.ms, at.offsetMin, source, now(), now());
  return { ...one<SessionRow>("SELECT * FROM sessions WHERE id=?", sid)!, created: true };
}

export function editSet(input: { id: string; delete?: boolean; restore?: boolean } & Partial<Omit<SetInput, "id">>) {
  const s = one<SetRow>("SELECT * FROM sets WHERE id=?", input.id);
  if (!s) throw httpErr(404, `No set ${input.id}`);
  if (input.delete) { run("UPDATE sets SET deleted_at=?,updated_at=? WHERE id=?", now(), now(), s.id); return { id: s.id, deleted: true }; }
  const fields: Record<string, unknown> = {};
  if (input.exercise !== undefined) {
    const r = resolveExercise(input.exercise);
    if ("candidates" in r) throw httpErr(422, `"${input.exercise}" is unclear: ${r.candidates.map((c) => `${c.name} (${c.id})`).join(", ") || "no match"}`);
    fields.exercise_id = r.exercise.id;
  }
  for (const k of ["kind", "weight_kg", "reps", "duration_s", "distance_m", "rpe", "rir", "target_weight_kg", "target_reps", "note"] as const)
    if (input[k] !== undefined) fields[k] = input[k];
  if (input.performed_at !== undefined) fields.performed_at = stampOrNow(input.performed_at).ms;
  if (input.restore) fields.deleted_at = null;
  const merged = { ...s, ...fields } as SetInput & SetRow;
  checkSet({ ...merged, exercise: merged.exercise_id });
  const keys = Object.keys(fields);
  if (!keys.length) throw httpErr(400, "Nothing to change");
  run(`UPDATE sets SET ${keys.map((k) => `${k}=?`).join(",")},updated_at=? WHERE id=?`, ...(keys.map((k) => fields[k]) as (string | number | null)[]), now(), s.id);
  const sess = one<SessionRow>("SELECT * FROM sessions WHERE id=?", s.session_id)!;
  return setView(one<SetRow>("SELECT * FROM sets WHERE id=?", s.id)!, sess.tz_offset_min);
}

export function editWorkout(input: { id: string; title?: string | null; notes?: string | null; ended_at?: string | null; delete?: boolean; restore?: boolean }) {
  const s = one<SessionRow>("SELECT * FROM sessions WHERE id=?", input.id);
  if (!s) throw httpErr(404, `No workout ${input.id}; Apple Watch workouts can't be edited here`);
  if (input.delete) { run("UPDATE sessions SET deleted_at=?,updated_at=? WHERE id=?", now(), now(), s.id); return { id: s.id, deleted: true }; }
  const f: Record<string, string | number | null> = {};
  if (input.title !== undefined) f.title = input.title;
  if (input.notes !== undefined) f.notes = input.notes;
  if (input.ended_at !== undefined) f.ended_at = input.ended_at === null ? null : stampOrNow(input.ended_at).ms;
  if (input.restore) f.deleted_at = null;
  const keys = Object.keys(f);
  if (!keys.length) throw httpErr(400, "Nothing to change");
  run(`UPDATE sessions SET ${keys.map((k) => `${k}=?`).join(",")},updated_at=? WHERE id=?`, ...keys.map((k) => f[k]), now(), s.id);
  return getWorkout(s.id);
}

const setView = (s: SetRow, off: number) => ({
  id: s.id, kind: s.kind, weight_kg: s.weight_kg, reps: s.reps, ...(s.duration_s != null && { duration_s: s.duration_s }),
  ...(s.distance_m != null && { distance_m: s.distance_m }), ...(s.rpe != null && { rpe: s.rpe }), ...(s.rir != null && { rir: s.rir }),
  ...(s.target_weight_kg != null && { target_weight_kg: s.target_weight_kg }), ...(s.target_reps != null && { target_reps: s.target_reps }),
  at: isoAt(s.performed_at, off), ...(s.note && { note: s.note }),
});

const liveSets = (sessionIds: string[]) => sessionIds.length
  ? all<SetRow>(`SELECT * FROM sets WHERE session_id IN (${marks(sessionIds.length)}) AND deleted_at IS NULL ORDER BY session_id, ord`, ...sessionIds) : [];

/** Session ids, exercises and sets in one shape for every read. */
function sessionView(s: SessionRow, sets: SetRow[], detail: boolean) {
  const end = s.ended_at ?? (sets.length ? Math.max(...sets.map((x) => x.performed_at)) : s.started_at);
  const byEx = new Map<string, SetRow[]>();
  for (const x of sets) byEx.set(x.exercise_id, [...(byEx.get(x.exercise_id) ?? []), x]);
  const muscles: Record<string, number> = {};
  let volume = 0, workingSets = 0;
  const exercises = [...byEx].map(([exId, xs]) => {
    const ex = getExercise(exId);
    const w = xs.filter(working);
    workingSets += w.length;
    for (const x of w) { volume += (x.weight_kg ?? 0) * (x.reps ?? 0); for (const m of ex?.primary ?? []) muscles[m] = (muscles[m] ?? 0) + 1; }
    const best = w.reduce<SetRow | null>((b, x) => ((e1rm(x.weight_kg, x.reps) ?? 0) > (e1rm(b?.weight_kg ?? null, b?.reps ?? null) ?? 0) ? x : b), null);
    return { exercise_id: exId, name: ex?.name ?? exId, working_sets: w.length,
      ...(best && { best_set: `${best.weight_kg ?? 0} kg × ${best.reps}`, e1rm_kg_estimate: e1rm(best.weight_kg, best.reps) }),
      ...(detail ? { sets: xs.map((x) => setView(x, s.tz_offset_min)) } : { sets: xs.map((x) => `${x.kind === "warmup" ? "w " : ""}${x.weight_kg ?? 0}×${x.reps ?? "-"}`).join(", ") }) };
  });
  const hr = all<{ id: string; name: string; hr_avg: number | null; hr_max: number | null; active_kcal: number | null }>(
    "SELECT id,name,hr_avg,hr_max,active_kcal FROM hk_workouts WHERE start_ms < ? AND end_ms > ?", end + 60_000, s.started_at - 60_000);
  return { id: s.id, type: "strength", title: s.title, day: localDay(s.started_at, s.tz_offset_min), start: isoAt(s.started_at, s.tz_offset_min),
    end: isoAt(end, s.tz_offset_min), duration_min: Math.round((end - s.started_at) / 60_000), open: s.ended_at === null,
    working_sets: workingSets, volume_kg: Math.round(volume), working_sets_by_muscle: muscles, exercises,
    watch: hr.length ? { workout_id: hr[0].id, name: hr[0].name, hr_avg: hr[0].hr_avg && Math.round(hr[0].hr_avg), hr_max: hr[0].hr_max, active_kcal_estimate: hr[0].active_kcal && Math.round(hr[0].active_kcal) }
      : "no Apple Watch workout overlaps this session, so there is no heart rate for it",
    ...(s.notes && { notes: s.notes }) };
}

const dayBounds = (from: string, to: string) => {
  const off = ownerOffsetMin();
  return [Date.parse(`${from}T00:00:00Z`) - off * 60_000 - 14 * 3_600_000, Date.parse(`${addDays(to, 1)}T00:00:00Z`) - off * 60_000 + 14 * 3_600_000];
};

export function listWorkouts(from: string, to: string) {
  const [a, b] = dayBounds(from, to);
  const sessions = all<SessionRow>("SELECT * FROM sessions WHERE deleted_at IS NULL AND started_at BETWEEN ? AND ? ORDER BY started_at DESC", a, b);
  const sets = liveSets(sessions.map((s) => s.id));
  const strength = sessions.map((s) => sessionView(s, sets.filter((x) => x.session_id === s.id), false))
    // A session whose sets were all deleted isn't a workout.
    .filter((v) => v.day >= from && v.day <= to && v.exercises.length > 0);
  const attached = new Set(strength.map((s) => (typeof s.watch === "object" ? s.watch.workout_id : "")));
  const watch = all<{ id: string; name: string; start: string; end: string; day: string; duration_s: number; active_kcal: number | null;
    hr_avg: number | null; hr_max: number | null; distance_km: number | null }>(
    "SELECT id,name,start,end,day,duration_s,active_kcal,hr_avg,hr_max,distance_km FROM hk_workouts WHERE day BETWEEN ? AND ? ORDER BY start_ms DESC", from, to)
    .filter((w) => !attached.has(w.id))
    .map((w) => ({ id: w.id, type: "watch", title: w.name, day: w.day, start: w.start, end: w.end, duration_min: Math.round(w.duration_s / 60),
      hr_avg: w.hr_avg && Math.round(w.hr_avg), hr_max: w.hr_max, active_kcal_estimate: w.active_kcal && Math.round(w.active_kcal),
      ...(w.distance_km && { distance_km: round(w.distance_km, 2) }) }));
  return [...strength, ...watch].sort((x, y) => y.start.localeCompare(x.start));
}

export function getWorkout(id: string) {
  const s = one<SessionRow>("SELECT * FROM sessions WHERE id=?", id);
  if (s) return { ...sessionView(s, liveSets([s.id]), true), ...(s.deleted_at && { deleted: true }) };
  const w = one<Record<string, unknown>>("SELECT id,name,start,end,day,duration_s,active_kcal,hr_min,hr_avg,hr_max,distance_km,source FROM hk_workouts WHERE id=?", id);
  if (!w) throw httpErr(404, `No workout ${id}`);
  return { ...w, type: "watch" };
}

type Perf = { session_id: string; day: string; title: string | null; sets: ReturnType<typeof setView>[]; best_set: string | null; e1rm_kg_estimate: number | null };

export function exerciseHistory(nameOrId: string, limit = 5) {
  const r = resolveExercise(nameOrId);
  if ("candidates" in r) throw httpErr(422, `"${nameOrId}" is unclear: ${r.candidates.map((c) => `${c.name} (${c.id})`).join(", ") || "no match; try find_exercises"}`);
  const ex = r.exercise;
  const rows = all<SetRow & { started_at: number; tz_offset_min: number; title: string | null }>(`SELECT t.*, s.started_at, s.tz_offset_min, s.title FROM sets t
    JOIN sessions s ON s.id=t.session_id WHERE t.exercise_id=? AND t.deleted_at IS NULL AND s.deleted_at IS NULL ORDER BY s.started_at DESC, t.ord`, ex.id);
  const bySession = new Map<string, typeof rows>();
  for (const x of rows) bySession.set(x.session_id, [...(bySession.get(x.session_id) ?? []), x]);
  const perfs: Perf[] = [...bySession].map(([sid, xs]) => {
    const w = xs.filter(working);
    const best = w.reduce<SetRow | null>((b, x) => ((e1rm(x.weight_kg, x.reps) ?? 0) > (e1rm(b?.weight_kg ?? null, b?.reps ?? null) ?? 0) ? x : b), null);
    return { session_id: sid, day: localDay(xs[0].started_at, xs[0].tz_offset_min), title: xs[0].title, sets: xs.map((x) => setView(x, x.tz_offset_min)),
      best_set: best ? `${best.weight_kg ?? 0} kg × ${best.reps}` : null, e1rm_kg_estimate: best ? e1rm(best.weight_kg, best.reps) : null };
  });
  const record = perfs.reduce<Perf | null>((b, p) => ((p.e1rm_kg_estimate ?? 0) > (b?.e1rm_kg_estimate ?? 0) ? p : b), null);
  const heaviest = rows.filter(working).reduce<number | null>((m, x) => (x.weight_kg != null && (m === null || x.weight_kg > m) ? x.weight_kg : m), null);
  return { exercise: { id: ex.id, name: ex.name, equipment: ex.equipment, primary: ex.primary, secondary: ex.secondary },
    sessions_total: perfs.length, recent: perfs.slice(0, limit),
    records: record ? { best_e1rm_kg_estimate: record.e1rm_kg_estimate, best_set: record.best_set, on: record.day, heaviest_kg: heaviest } : null,
    next: perfs[0] ? suggest(ex, perfs[0]) : { rule: "no history", suggestion: "No sets logged for this exercise yet." } };
}

/** Double progression: when every working set hit its target reps, add one load step; otherwise repeat the weight. */
function suggest(ex: Exercise, last: Perf) {
  const w = last.sets.filter((s) => s.kind !== "warmup" && s.reps != null);
  if (!w.length) return { rule: "no working sets last time", suggestion: "Last session had only warm-ups." };
  const weight = Math.max(...w.map((s) => s.weight_kg ?? 0));
  const top = w.filter((s) => (s.weight_kg ?? 0) === weight);
  const target = top[0].target_reps ?? top[0].reps!;
  const hit = top.every((s) => (s.reps ?? 0) >= (s.target_reps ?? target));
  const step = ex.equipment === "dumbbell" || ex.equipment === "kettlebells" ? 2 : ex.equipment === "body only" || !weight ? 0 : 2.5;
  const rule = `double progression on the top working weight; step ${step ? `${step} kg (${ex.equipment ?? "unknown equipment"})` : "1 rep (bodyweight)"}`;
  if (hit && step) return { rule, last_top: `${weight} kg × ${top.map((s) => s.reps).join(", ")}`, suggestion: `${weight + step} kg × ${target} for ${top.length} sets` };
  if (hit) return { rule, last_top: `${weight} kg × ${top.map((s) => s.reps).join(", ")}`, suggestion: `${target + 1} reps per set` };
  return { rule, last_top: `${weight} kg × ${top.map((s) => s.reps).join(", ")}`, suggestion: `stay at ${weight} kg until every set reaches ${target} reps` };
}

export function trainingSummary(from: string, to: string) {
  const list = listWorkouts(from, to);
  const strength = list.filter((w) => w.type === "strength") as ReturnType<typeof sessionView>[];
  const byMuscle: Record<string, number> = {}, secondary: Record<string, number> = {};
  let volume = 0;
  const ids = strength.map((s) => s.id);
  for (const x of liveSets(ids).filter(working)) {
    const ex = getExercise(x.exercise_id);
    volume += (x.weight_kg ?? 0) * (x.reps ?? 0);
    for (const m of ex?.primary ?? []) byMuscle[m] = (byMuscle[m] ?? 0) + 1;
    for (const m of ex?.secondary ?? []) secondary[m] = (secondary[m] ?? 0) + 1;
  }
  // Records: a best estimated 1RM in the window above every earlier one for that exercise.
  const [a, b] = dayBounds(from, to);
  const records = all<{ exercise_id: string; weight_kg: number; reps: number; performed_at: number; prior: number | null }>(`
    SELECT t.exercise_id, t.weight_kg, t.reps, t.performed_at,
      (SELECT MAX(CASE WHEN p.reps = 1 THEN p.weight_kg ELSE p.weight_kg * (1 + p.reps / 30.0) END) FROM sets p JOIN sessions ps ON ps.id=p.session_id
        WHERE p.exercise_id=t.exercise_id AND p.performed_at < ? AND p.deleted_at IS NULL AND ps.deleted_at IS NULL AND p.kind!='warmup' AND p.reps BETWEEN 1 AND 12) prior
    FROM sets t JOIN sessions s ON s.id=t.session_id
    WHERE t.performed_at BETWEEN ? AND ? AND t.deleted_at IS NULL AND s.deleted_at IS NULL AND t.kind!='warmup' AND t.reps BETWEEN 1 AND 12 AND t.weight_kg > 0`, a, a, b)
    .reduce<Map<string, { e: number; set: string; prior: number | null }>>((m, r) => {
      const e = e1rm(r.weight_kg, r.reps)!;
      if (!m.has(r.exercise_id) || e > m.get(r.exercise_id)!.e) m.set(r.exercise_id, { e, set: `${r.weight_kg} kg × ${r.reps}`, prior: r.prior && round(r.prior, 1) });
      return m;
    }, new Map());
  const prs = [...records].filter(([, v]) => v.prior === null || v.e > v.prior)
    .map(([id, v]) => ({ exercise: getExercise(id)?.name ?? id, set: v.set, e1rm_kg_estimate: v.e, previous_best_estimate: v.prior, first_time: v.prior === null }));
  return { range: `${from}..${to}`, strength_sessions: strength.length, watch_workouts: list.length - strength.length,
    watch_minutes: list.filter((w) => w.type === "watch").reduce((n, w) => n + w.duration_min, 0),
    working_sets_by_muscle: byMuscle, secondary_muscle_sets: secondary, volume_kg: Math.round(volume), records: prs,
    days_since_trained: daysSinceTrained(to), counting: "working sets only (warm-ups excluded); a set counts once for each primary muscle" };
}

/** Days since each major muscle last had a working set, as of the end of `day`. null = never logged. */
export function daysSinceTrained(day: string) {
  const [, b] = dayBounds(day, day);
  const rows = all<{ exercise_id: string; last: number; off: number }>(`SELECT t.exercise_id, MAX(t.performed_at) last, s.tz_offset_min off FROM sets t
    JOIN sessions s ON s.id=t.session_id WHERE t.deleted_at IS NULL AND s.deleted_at IS NULL AND t.kind!='warmup' AND t.performed_at <= ? GROUP BY t.exercise_id`, b);
  const last: Record<string, string> = {};
  for (const r of rows) {
    const d = localDay(r.last, r.off);
    for (const m of getExercise(r.exercise_id)?.primary ?? []) if (!last[m] || d > last[m]) last[m] = d;
  }
  return Object.fromEntries(MAJOR_MUSCLES.map((m) => [m, last[m] ? Math.round((Date.parse(`${day}T00:00:00Z`) - Date.parse(`${last[m]}T00:00:00Z`)) / 86_400_000) : null]));
}

export function lastTraining(day: string) {
  const s = one<SessionRow>("SELECT * FROM sessions WHERE deleted_at IS NULL AND started_at <= ? ORDER BY started_at DESC LIMIT 1", dayBounds(day, day)[1]);
  const w = one<{ id: string; name: string; day: string; start: string; duration_s: number }>("SELECT id,name,day,start,duration_s FROM hk_workouts WHERE day <= ? ORDER BY start_ms DESC LIMIT 1", day);
  const sDay = s ? localDay(s.started_at, s.tz_offset_min) : null;
  const strength = s && sDay! <= day ? { id: s.id, title: s.title, day: sDay!, days_ago: Math.round((Date.parse(`${day}T00:00:00Z`) - Date.parse(`${sDay}T00:00:00Z`)) / 86_400_000) } : null;
  const watch = w ? { id: w.id, name: w.name, day: w.day, minutes: Math.round(w.duration_s / 60), days_ago: Math.round((Date.parse(`${day}T00:00:00Z`) - Date.parse(`${w.day}T00:00:00Z`)) / 86_400_000) } : null;
  return { last_strength_session: strength, last_watch_workout: watch };
}
