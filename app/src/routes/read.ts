import { Hono } from "hono";
import { ApiError, dayParam, handle, routeKey, withEtag } from "../http.js";
import { catalog, exerciseDetail } from "../exercise-view.js";
import { sleepDay, sleepWeek } from "../sleep-view.js";
import { bodyDay } from "../weight.js";
import { getTargets } from "../targets.js";
import { digestBody, todayBody } from "../today.js";
import { sessionDetail, sessionHistory, trainingWeek } from "../training-view.js";

export const readRoutes = new Hono();

readRoutes.get("/v2/targets", handle("v2/targets", "read", (c) => withEtag(c, routeKey(c), () => getTargets())));
readRoutes.get("/v2/today", handle("v2/today", "read", (c) => withEtag(c, routeKey(c), () => todayBody(dayParam(c)), { clock: true })));
readRoutes.get("/v2/digest", handle("v2/digest", "read", (c) => withEtag(c, routeKey(c), () => digestBody(dayParam(c)), { clock: true })));
readRoutes.get("/v2/sleep", handle("v2/sleep", "read", (c) => withEtag(c, routeKey(c), () => sleepDay(dayParam(c)))));
readRoutes.get("/v2/sleep/week", handle("v2/sleep/week", "read", (c) => withEtag(c, routeKey(c), () => sleepWeek(dayParam(c, "end")))));
readRoutes.get("/v2/body", handle("v2/body", "read", (c) => withEtag(c, routeKey(c), () => bodyDay(dayParam(c)))));
readRoutes.get("/v2/training", handle("v2/training", "read", (c) => withEtag(c, routeKey(c), () => trainingWeek(dayParam(c, "week")), { clock: true })));
readRoutes.get("/v2/training/sessions", handle("v2/training/sessions", "read", (c) => {
  const limit = Number(c.req.query("limit") ?? 20);
  if (!Number.isInteger(limit) || limit < 1 || limit > 50) throw new ApiError(400, "limit must be 1–50", "bad_request");
  return withEtag(c, routeKey(c), () => sessionHistory(c.req.query("before") || undefined, limit));
}));
readRoutes.get("/v2/training/sessions/:id", handle("v2/training/session", "read", (c) => withEtag(c, routeKey(c), () => sessionDetail(c.req.param("id") ?? ""))));
readRoutes.get("/v2/exercises", handle("v2/exercises", "read", (c) => withEtag(c, routeKey(c), () => catalog(c.req.query("q") || undefined, c.req.query("since") || undefined))));
readRoutes.get("/v2/exercises/:id", handle("v2/exercise", "read", (c) => withEtag(c, routeKey(c), () => exerciseDetail(c.req.param("id") ?? ""))));
