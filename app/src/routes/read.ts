import { Hono } from "hono";
import { dayParam, handle, routeKey, withEtag } from "../http.js";
import { getTargets } from "../targets.js";
import { digestBody, todayBody } from "../today.js";

export const readRoutes = new Hono();

readRoutes.get("/v2/targets", handle("v2/targets", "read", (c) => withEtag(c, routeKey(c), () => getTargets())));
readRoutes.get("/v2/today", handle("v2/today", "read", (c) => withEtag(c, routeKey(c), () => todayBody(dayParam(c)), { clock: true })));
readRoutes.get("/v2/digest", handle("v2/digest", "read", (c) => withEtag(c, routeKey(c), () => digestBody(dayParam(c)), { clock: true })));
