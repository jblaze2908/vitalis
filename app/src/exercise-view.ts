// Exercise catalog and exercise detail bodies (spec 10 §6). Muscles go out as hyphen slugs; custom ones may be posted
// with either spelling.
import { z } from "zod";
import { all, one } from "./db.js";
import { createExercise, findExercises, getExercise, MUSCLES, type Exercise } from "./exercises.js";
import { freshnessBlock } from "./health.js";
import { ApiError } from "./http.js";
import { parseStamp, today } from "./time.js";
import { exerciseRecord } from "./training.js";
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
    freshness: freshnessBlock(at),
  };
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
