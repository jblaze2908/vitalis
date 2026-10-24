import { Hono } from "hono";
import { newExerciseSchema, postExercise } from "../exercise-view.js";
import { handle, readJson, setDetail } from "../http.js";
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

writeRoutes.post("/v2/exercises", handle("v2/exercises:post", "write", async (c) => c.json(postExercise(await readJson(c, newExerciseSchema)))));
