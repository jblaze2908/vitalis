import { Hono } from "hono";
import { ApiError, dayParam, handle, routeKey, withEtag } from "../http.js";
import { catalog, exerciseDetail, performedExercises } from "../exercise-view.js";
import { heartDay } from "../heart.js";
import { metricHistory, metricsOverview } from "../metric-view.js";
import { sleepDay, sleepMonth, sleepWeek } from "../sleep-view.js";
import { bodyDay } from "../weight.js";
import { definedSplits } from "../splits.js";
import { getTargets } from "../targets.js";
import { digestBody, todayBody } from "../today.js";
import { sessionDetail, sessionHistory, trainingWeek } from "../training-view.js";

export const readRoutes = new Hono();

readRoutes.get("/v2/targets", handle("v2/targets", "read", (c) => withEtag(c, routeKey(c), () => getTargets())));
readRoutes.get("/v2/splits", handle("v2/splits", "read", (c) => withEtag(c, routeKey(c), () => ({ splits: definedSplits() }))));
readRoutes.get("/v2/today", handle("v2/today", "read", (c) => withEtag(c, routeKey(c), () => todayBody(dayParam(c)), { clock: true })));
readRoutes.get("/v2/digest", handle("v2/digest", "read", (c) => withEtag(c, routeKey(c), () => digestBody(dayParam(c)), { clock: true })));
readRoutes.get("/v2/sleep", handle("v2/sleep", "read", (c) => withEtag(c, routeKey(c), () => sleepDay(dayParam(c)))));
readRoutes.get("/v2/sleep/month", handle("v2/sleep/month", "read", (c) => withEtag(c, routeKey(c), () => sleepMonth(monthParam(c)))));
readRoutes.get("/v2/sleep/week", handle("v2/sleep/week", "read", (c) => withEtag(c, routeKey(c), () => sleepWeek(dayParam(c, "end")))));
readRoutes.get("/v2/body", handle("v2/body", "read", (c) => withEtag(c, routeKey(c), () => bodyDay(dayParam(c)))));
readRoutes.get("/v2/training", handle("v2/training", "read", (c) => withEtag(c, routeKey(c), () => trainingWeek(dayParam(c, "week")), { clock: true })));
readRoutes.get("/v2/training/sessions", handle("v2/training/sessions", "read", (c) => {
  const limit = Number(c.req.query("limit") ?? 20);
  if (!Number.isInteger(limit) || limit < 1 || limit > 50) throw new ApiError(400, "limit must be 1–50", "bad_request");
  return withEtag(c, routeKey(c), () => sessionHistory(c.req.query("before") || undefined, limit));
}));
readRoutes.get("/v2/training/exercises", handle("v2/training/exercises", "read", (c) => withEtag(c, routeKey(c), () => performedExercises())));
readRoutes.get("/v2/heart", handle("v2/heart", "read", (c) => withEtag(c, routeKey(c), () => heartDay(dayParam(c)), { clock: true })));
readRoutes.get("/v2/metrics", handle("v2/metrics", "read", (c) => withEtag(c, routeKey(c), () => metricsOverview(dayParam(c)))));
readRoutes.get("/v2/metrics/:key", handle("v2/metric", "read", (c) => withEtag(c, routeKey(c),
  () => metricHistory(c.req.param("key") ?? "", Number(c.req.query("days") ?? 30), dayParam(c, "end")))));
readRoutes.get("/v2/training/sessions/:id", handle("v2/training/session", "read", (c) => withEtag(c, routeKey(c), () => sessionDetail(c.req.param("id") ?? ""))));
readRoutes.get("/v2/exercises", handle("v2/exercises", "read", (c) => withEtag(c, routeKey(c), () => catalog(c.req.query("q") || undefined, c.req.query("since") || undefined))));
readRoutes.get("/v2/exercises/:id", handle("v2/exercise", "read", (c) => withEtag(c, routeKey(c), () => exerciseDetail(c.req.param("id") ?? ""))));

/** `month=YYYY-MM`, default this month; a future month is a 400 like a future date. */
function monthParam(c: Parameters<typeof dayParam>[0]) {
  const raw = c.req.query("month"), t = dayParam(c, "__none__").slice(0, 7);
  if (raw === undefined || raw === "") return t;
  if (!/^\d{4}-(0[1-9]|1[0-2])$/.test(raw)) throw new ApiError(400, "month must look like 2026-10", "bad_request");
  if (raw > t) throw new ApiError(400, "month is in the future", "bad_request");
  return raw;
}
