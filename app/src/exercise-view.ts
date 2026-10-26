// Exercise catalog and exercise detail bodies (spec 10 §6). Muscles go out as hyphen slugs; custom ones may be posted
// with either spelling.
import { z } from "zod";
import { all, one } from "./db.js";
import { createExercise, findExercises, getExercise, MUSCLES, type Exercise } from "./exercises.js";
import { freshnessBlock } from "./health.js";
import { ApiError } from "./http.js";
import { localDay, parseStamp, today } from "./time.js";
import { e1rm, exerciseRecord } from "./training.js";
import { e1rmTrend, fromSlug, toSlug } from "./training-analytics.js";

export const exerciseView = (e: Exercise) => ({ id: e.id, name: e.name, equipment: e.equipment, primary: e.primary.map(toSlug),
  secondary: e.secondary.map(toSlug), aliases: e.aliases, custom: e.custom });

export function catalog(q: string | undefined, since: string | undefined) {
  let list: Exercise[];
  if (q) list = findExercises(q, 25);
  else if (since) {
    const t = parseStamp(since);
    if (!t) throw new ApiError(400, "since must be an ISO 8601 time", "bad_request");
    list = all<{ id: string }>("SELECT id FROM exercises WHERE custom=1 AND created_at>? ORDER BY created_at", t.ms).map((r) => getExercise(r.id)!).filter(Boolean);
  } else list = all<{ id: string }>("SELECT id FROM exercises ORDER BY name").map((r) => getExercise(r.id)!).filter(Boolean);
  return { generated_at: new Date().toISOString(), count: list.length, exercises: list.map(exerciseView) };
}

export function exerciseDetail(id: string, at = Date.now()) {
  const ex = getExercise(id);
  if (!ex) throw new ApiError(404, `No exercise ${id}`);
  const h = exerciseRecord(ex.id, 1);
  const points = h.perfs.filter((p) => p.e1rm_kg_estimate !== null).map((p) => ({ day: p.day, kg: p.e1rm_kg_estimate!, session_id: p.session_id }));
  const trend = e1rmTrend(points, today(at)), last = h.perfs[0];
  return {
    exercise: { id: ex.id, name: ex.name, equipment: ex.equipment, primary: ex.primary.map(toSlug), secondary: ex.secondary.map(toSlug) },
    context_label: [ex.equipment, [...ex.primary, ...ex.secondary].join(", ")].filter(Boolean).join(" · ").toUpperCase(),
    e1rm: { current_kg: trend.current_kg, change_8w_kg: trend.change_8w_kg, points: trend.points, estimate: true },
    records: h.records && { best_e1rm_kg: h.records.best_e1rm_kg_estimate, best_set: h.records.best_set, on: h.records.on, heaviest_kg: h.records.heaviest_kg },
    next: h.next,
    last_session: last ? { session_id: last.session_id, day: last.day, sets: last.sets.map((s) => ({ kind: s.kind, weight_kg: s.weight_kg, reps: s.reps })) } : null,
    sessions_total: h.sessions_total,
    history: h.perfs.slice(0, 30).map((p) => ({ session_id: p.session_id, day: p.day, title: p.title, best_set: p.best_set, e1rm_kg: p.e1rm_kg_estimate,
      volume_kg: Math.round(p.sets.filter((x) => x.kind !== "warmup").reduce((v, x) => v + (x.weight_kg ?? 0) * (x.reps ?? 0), 0)),
      sets: p.sets.map((x) => ({ kind: x.kind, weight_kg: x.weight_kg, reps: x.reps })) })),
    freshness: freshnessBlock(at),
  };
}

type Done = { exercise_id: string; session_id: string; weight_kg: number | null; reps: number | null; started_at: number; tz_offset_min: number };
type Acc = { sessions: Map<string, { day: string; best: number | null; top: { weight_kg: number | null; reps: number | null } }>; sets: number; heaviest: number | null; last: number };

/** `/v2/training/exercises`: every exercise with a working set, most recent first. One scan of live sets per request. */
export function performedExercises(at = Date.now()) {
  const acc = new Map<string, Acc>();
  for (const r of all<Done>(`SELECT t.exercise_id,t.session_id,t.weight_kg,t.reps,s.started_at,s.tz_offset_min FROM sets t JOIN sessions s ON s.id=t.session_id
    WHERE t.deleted_at IS NULL AND s.deleted_at IS NULL AND t.kind!='warmup' ORDER BY s.started_at, t.performed_at`)) {
    const a = acc.get(r.exercise_id) ?? { sessions: new Map(), sets: 0, heaviest: null, last: 0 };
    acc.set(r.exercise_id, a);
    a.sets++; a.last = Math.max(a.last, r.started_at);
    if (r.weight_kg != null && (a.heaviest === null || r.weight_kg > a.heaviest)) a.heaviest = r.weight_kg;
    const s = a.sessions.get(r.session_id) ?? { day: localDay(r.started_at, r.tz_offset_min), best: null, top: { weight_kg: r.weight_kg, reps: r.reps } };
    a.sessions.set(r.session_id, s);
    const est = e1rm(r.weight_kg, r.reps);
    if (est !== null && (s.best === null || est > s.best)) s.best = est;
    if ((r.weight_kg ?? 0) > (s.top.weight_kg ?? 0) || ((r.weight_kg ?? 0) === (s.top.weight_kg ?? 0) && (r.reps ?? 0) > (s.top.reps ?? 0))) s.top = { weight_kg: r.weight_kg, reps: r.reps };
  }
  const t = today(at);
  const list = [...acc].sort(([, a], [, b]) => b.last - a.last).flatMap(([id, a]) => {
    const ex = getExercise(id);
    if (!ex) return [];
    const perfs = [...a.sessions].map(([session_id, p]) => ({ session_id, ...p }));
    const points = perfs.filter((p) => p.best !== null).map((p) => ({ day: p.day, kg: p.best!, session_id: p.session_id }));
    const trend = e1rmTrend(points, t), last = perfs.at(-1)!;
    return [{ id, name: ex.name, equipment: ex.equipment, primary: ex.primary.map(toSlug), sessions: perfs.length, working_sets: a.sets,
      last_day: last.day, last_top: last.top, heaviest_kg: a.heaviest, best_e1rm_kg: points.length ? Math.max(...points.map((p) => p.kg)) : null,
      e1rm_kg: trend.current_kg, change_8w_kg: trend.change_8w_kg, spark: points.slice(-12).map((p) => p.kg) }];
  });
  return { count: list.length, exercises: list, freshness: freshnessBlock(at) };
}

const muscle = z.string().transform((m) => fromSlug(m.trim().toLowerCase())).refine((m) => MUSCLES.includes(m), "must be one of the 17 muscles");
export const newExerciseSchema = z.strictObject({
  name: z.string().min(2).max(80), primary: z.array(muscle).min(1).max(4), secondary: z.array(muscle).max(6).optional(),
  equipment: z.string().max(40).nullable().optional(), aliases: z.array(z.string().max(60)).max(10).optional(),
});
export function postExercise(input: z.infer<typeof newExerciseSchema>) {
  const r = createExercise(input);
  return { exercise: exerciseView(r.exercise), created: r.created };
}
export const exerciseCount = () => one<{ n: number }>("SELECT COUNT(*) n FROM exercises")!.n;
