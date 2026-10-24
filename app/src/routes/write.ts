import { Hono } from "hono";
import { handle, readJson, setDetail } from "../http.js";
import { getTargets, putSchema, putTargets } from "../targets.js";

export const writeRoutes = new Hono();

writeRoutes.put("/v2/targets", handle("v2/targets:put", "write", async (c) => {
  const body = await readJson(c, putSchema);
  putTargets(body);
  setDetail(c, `${Object.keys(body).length} keys`);
  return c.json(getTargets());
}));
