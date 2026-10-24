import { Hono } from "hono";
import { deleteEntries, deleteSaved, entriesSchema, foodDay, foodQuick, postEntries, putSaved, savedSchema, slotAt, SLOTS, type Slot } from "../food.js";
import { ApiError, dayParam, handle, readJson, routeKey, setDetail, withEtag } from "../http.js";
import { barcode, barcodePutSchema, putBarcode, searchFood } from "../off.js";
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

// External data, not the owner's: a plain max-age instead of ETags (10 §1.4).
const PUBLIC_CACHE = { "Cache-Control": "private, max-age=3600" };
foodRoutes.get("/v2/food/search", handle("v2/food/search", "read", async (c) => {
  const page = Number(c.req.query("page") ?? 1);
  if (!Number.isInteger(page)) throw new ApiError(400, "page must be a whole number", "bad_request");
  const r = await searchFood(c.req.query("q") ?? "", page);
  setDetail(c, `${r.count} results, remote ${r.remote}`);
  return c.json(r, 200, PUBLIC_CACHE);
}));
foodRoutes.get("/v2/food/barcode/:code", handle("v2/food/barcode", "read", async (c) => c.json(await barcode(c.req.param("code") ?? ""), 200, PUBLIC_CACHE)));
foodRoutes.put("/v2/food/barcode/:code", handle("v2/food/barcode:put", "write", async (c) =>
  c.json(putBarcode(c.req.param("code") ?? "", (await readJson(c, barcodePutSchema)).item))));
