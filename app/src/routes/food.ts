import { Hono } from "hono";
import { deleteEntries, deleteSaved, entriesSchema, foodDay, foodQuick, postEntries, putSaved, savedSchema, slotAt, SLOTS, type Slot } from "../food.js";
import { ApiError, dayParam, handle, readJson, routeKey, setDetail, withEtag } from "../http.js";
import { ownerOffsetMin } from "../time.js";

export const foodRoutes = new Hono();

foodRoutes.get("/v2/food/day", handle("v2/food/day", "read", (c) => withEtag(c, routeKey(c), () => foodDay(dayParam(c)), { clock: true })));

foodRoutes.get("/v2/food/quick", handle("v2/food/quick", "read", (c) => {
  const raw = c.req.query("slot");
  if (raw !== undefined && !(SLOTS as readonly string[]).includes(raw)) throw new ApiError(400, `slot is one of ${SLOTS.join(", ")}`, "bad_request");
  const at = Date.now(), d = new Date(at + ownerOffsetMin(at) * 60_000);
  const slot = (raw as Slot | undefined) ?? slotAt(d.getUTCHours() * 60 + d.getUTCMinutes());
  return withEtag(c, routeKey(c), () => foodQuick(slot, at), { clock: true });
}));

foodRoutes.post("/v2/food/entries", handle("v2/food/entries", "write", async (c) => {
  const r = postEntries(await readJson(c, entriesSchema));
  setDetail(c, JSON.stringify(r.accepted));
  return c.json({ accepted: r.accepted, day: foodDay(r.day) });
}));

foodRoutes.delete("/v2/food/entries/:id", handle("v2/food/entries:delete", "write", (c) => {
  const r = deleteEntries("id", c.req.param("id") ?? "");
  return c.json({ deleted: r.deleted, day: foodDay(r.day) });
}));

foodRoutes.delete("/v2/food/meals/:meal_id", handle("v2/food/meals:delete", "write", (c) => {
  const r = deleteEntries("meal_id", c.req.param("meal_id") ?? "");
  setDetail(c, `${r.deleted} entries`);
  return c.json({ deleted: r.deleted, day: foodDay(r.day) });
}));

foodRoutes.post("/v2/food/saved", handle("v2/food/saved", "write", async (c) => c.json(putSaved(await readJson(c, savedSchema)))));
foodRoutes.delete("/v2/food/saved/:id", handle("v2/food/saved:delete", "write", (c) => c.json(deleteSaved(c.req.param("id") ?? ""))));
