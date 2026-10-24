import { Hono } from "hono";
import { handle, routeKey, withEtag } from "../http.js";
import { getTargets } from "../targets.js";

export const readRoutes = new Hono();

readRoutes.get("/v2/targets", handle("v2/targets", "read", (c) => withEtag(c, routeKey(c), () => getTargets())));
