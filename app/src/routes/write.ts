import { Hono } from "hono";
import { newExerciseSchema, postExercise } from "../exercise-view.js";
import { z } from "zod";
import { ApiError, handle, readJson, setDetail } from "../http.js";
import { KINDS, upsertWorkout } from "../training.js";
import { sessionDetail, sessionPRs } from "../training-view.js";
import { deleteSplit, putSplit, splitSchema } from "../splits.js";
import { getTargets, putSchema, putTargets } from "../targets.js";
import { deleteWeight, postWeight, weightNow, weightSchema } from "../weight.js";

export const writeRoutes = new Hono();

writeRoutes.put("/v2/targets", handle("v2/targets:put", "write", async (c) => {
  const body = await readJson(c, putSchema);
  putTargets(body);
  setDetail(c, `${Object.keys(body).length} keys`);
  return c.json(getTargets());
}));

writeRoutes.post("/v2/weight", handle("v2/weight", "write", async (c) => {
  const entry = postWeight(await readJson(c, weightSchema));
  setDetail(c, entry.changed ? "1 entry" : "unchanged");
  return c.json({ entry: { id: entry.id, kg: entry.kg, day: entry.day }, weight: weightNow() });
}));

writeRoutes.delete("/v2/weight/:id", handle("v2/weight:delete", "write", (c) => {
  deleteWeight(c.req.param("id") ?? "");
  return c.json({ weight: weightNow() });
}));

writeRoutes.put("/v2/splits/:id", handle("v2/splits:put", "write", async (c) => c.json(putSplit(c.req.param("id") ?? "", await readJson(c, splitSchema)))));
writeRoutes.delete("/v2/splits/:id", handle("v2/splits:delete", "write", (c) => c.json(deleteSplit(c.req.param("id") ?? ""))));

writeRoutes.post("/v2/exercises", handle("v2/exercises:post", "write", async (c) => c.json(postExercise(await readJson(c, newExerciseSchema)))));

const when = z.string().min(10).max(40);
const num = (lo: number, hi: number) => z.number().min(lo).max(hi).nullable().optional();
const workoutSchema = z.strictObject({
  session: z.strictObject({
    client_id: z.string().min(1).max(64), title: z.string().max(80).nullable().optional(), template: z.string().min(1).max(80).nullable().optional(),
    source: z.enum(["watch", "phone"]), started_at: when, ended_at: when.nullable().optional(), tz_offset_min: z.number().int().min(-840).max(840),
    hk_workout_uuid: z.string().min(1).max(64).nullable().optional(), notes: z.string().max(2000).nullable().optional(),
  }),
  sets: z.array(z.strictObject({
    id: z.string().min(1).max(64), exercise: z.string().min(1).max(120).optional(), kind: z.enum(KINDS).optional(),
    weight_kg: num(0, 1000), reps: z.number().int().min(0).max(1000).nullable().optional(), duration_s: num(0, 86400), distance_m: num(0, 1e6),
    rpe: num(1, 10), rir: z.number().int().min(0).max(20).nullable().optional(), target_weight_kg: num(0, 1000),
    target_reps: z.number().int().min(0).max(1000).nullable().optional(), performed_at: when.optional(), note: z.string().max(500).nullable().optional(),
    deleted: z.boolean().optional(),
  })).max(200),
});

writeRoutes.post("/v2/workouts", handle("v2/workouts", "write", async (c, token) => {
  const body = await readJson(c, workoutSchema);
  let r;
  try { r = upsertWorkout(body as Parameters<typeof upsertWorkout>[0], token.name); }
  catch (e) {
    const u = (e as { unclear?: unknown }).unclear;
    if (u) throw new ApiError(422, (e as Error).message, "invalid", { candidates: u });
    throw e;
  }
  setDetail(c, JSON.stringify(r.accepted));
  const prs = sessionPRs(r.id).filter((p) => !p.first_time && p.e1rm_kg_estimate > p.previous_best_estimate!)
    .map(({ first_time: _f, ...p }) => p);
  return c.json({ session: sessionDetail(r.id), accepted: r.accepted, prs });
}));
