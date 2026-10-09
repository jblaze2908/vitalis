// The MCP endpoint: stateless Streamable HTTP at /mcp, bearer tokens only. A read token sees the read tools; a write
// token also sees the four write tools. Every call is recorded (tool, outcome, time), never the values.
import { McpServer, OAuthError, OAuthErrorCode, bearerAuthChallengeResponse, createMcpHandler } from "@modelcontextprotocol/server";
import type { Context } from "hono";
import { z } from "zod";
import { HOST, HttpError } from "./config.js";
import { MUSCLES, createExercise, findExercises } from "./exercises.js";
import { brief, freshness, getMetrics, getSleep } from "./health.js";
import { addDays, DAY_RE, today } from "./time.js";
import { authenticate, logCall, type Token } from "./tokens.js";
import { KINDS, editSet, editWorkout, exerciseHistory, getWorkout, listWorkouts, logSets, trainingSummary } from "./training.js";

export const INSTRUCTIONS = `Vitalis holds one person's health record: Apple Health data synced from their iPhone (sleep, heart, activity, weight, Watch workouts) and a strength-training log.
- Days are the person's local days. A night of sleep belongs to the day they woke up.
- Values come with "usual": their median over the 30 days before, and a usual range (10th–90th percentile). Quote these; don't compute your own.
- "flag" low/high means outside the usual range; "reading" better/worse says which way is good for that metric.
- A missing day is not zero. Check "freshness" (last_sync, latest_day) before saying they didn't sleep, walk or train.
- Watch energy, VO2 max and estimated 1RM are estimates; say so when you use them.
- Start with get_brief for "how am I today". Use find_exercises when an exercise name might be ambiguous.
- log_sets is safe to retry when you pass your own set ids.`;

const day = z.string().regex(DAY_RE, "a date like 2026-10-09");
const when = z.string().min(10).max(40).describe("ISO 8601 time with offset, e.g. 2026-10-09T19:05:00+05:30");
const Out = z.looseObject({});

type Ctx = { token: Token };
const ok = (v: unknown) => ({ content: [{ type: "text" as const, text: JSON.stringify(v) }], structuredContent: v as Record<string, unknown> });
const fail = (msg: string) => ({ isError: true, content: [{ type: "text" as const, text: msg }] });

function wrap<A>(ctx: Ctx, tool: string, fn: (a: A) => unknown, detail?: (r: unknown) => string) {
  return (a: A) => {
    const t0 = Date.now();
    try {
      const r = fn(a);
      logCall(ctx.token.id, tool, true, Date.now() - t0, detail ? detail(r) : null);
      return ok(r);
    } catch (e) {
      const err = e as HttpError;
      const known = err instanceof HttpError && err.status < 500;
      if (!known) console.error(`mcp ${tool} failed:`, err.message);
      logCall(ctx.token.id, tool, false, Date.now() - t0, known ? err.message.slice(0, 200) : "internal error");
      return fail(known ? err.message : "Vitalis couldn't do that; the error is in the server log.");
    }
  };
}

const span = (a: { from?: string; to?: string }, days: number) => {
  const to = a.to ?? today(), from = a.from ?? addDays(to, -(days - 1));
  return [from, to] as const;
};
const READ = { readOnlyHint: true, openWorldHint: false };

const SetIn = z.object({
  id: z.string().min(8).max(64).optional().describe("your own id for this set (a UUID); a set id seen before is skipped, so retries are safe"),
  exercise: z.string().min(1).max(120).describe("exercise name or id, e.g. 'bench press' or 'barbell-bench-press-medium-grip'"),
  kind: z.enum(KINDS).optional().describe("warmup sets never count toward volume or records; default normal"),
  weight_kg: z.number().min(0).max(1000).nullable().optional().describe("load in kg; for dumbbells, one dumbbell"),
  reps: z.number().int().min(0).max(1000).nullable().optional(),
  duration_s: z.number().min(0).max(86400).nullable().optional(), distance_m: z.number().min(0).max(1e6).nullable().optional(),
  rpe: z.number().min(1).max(10).nullable().optional(), rir: z.number().int().min(0).max(20).nullable().optional(),
  target_weight_kg: z.number().min(0).max(1000).nullable().optional(), target_reps: z.number().int().min(0).max(1000).nullable().optional(),
  performed_at: when.optional().describe("when the set was done; default now"), note: z.string().max(500).nullable().optional(),
});

export function buildServer(token: Token) {
  const ctx: Ctx = { token };
  const s = new McpServer({ name: "vitalis", version: "0.1.0" }, { instructions: INSTRUCTIONS });

  s.registerTool("get_brief", { title: "Today's check", annotations: READ, outputSchema: Out,
    description: "Today's check: last night's sleep, resting heart rate, HRV and breathing against the person's usual; yesterday's activity; weight trend; last training and muscles not trained for 7+ days; a rule-based call (easy, as planned, normal, good) and a summary paragraph to quote. Start here for 'how did I sleep', 'should I train hard today', 'how am I doing'.",
    inputSchema: z.object({ day: day.optional().describe("the day to check; default today in the person's time zone") }) },
  wrap(ctx, "get_brief", (a: { day?: string }) => brief(a.day)));

  s.registerTool("get_sleep", { title: "Sleep by night", annotations: READ, outputSchema: Out,
    description: "Nights of sleep between two dates, keyed by the day they woke up: time asleep, when they fell asleep and woke, deep, REM and awake time, nights outside the usual flagged, and the range's average against the usual before it. For sleep trends, bedtime drift, 'how did I sleep this week'.",
    inputSchema: z.object({ from: day.optional().describe("default 6 days before to"), to: day.optional().describe("default today") }) },
  wrap(ctx, "get_sleep", (a: { from?: string; to?: string }) => getSleep(...span(a, 7))));

  s.registerTool("get_metrics", { title: "Health metrics over time", annotations: READ, outputSchema: Out,
    description: "Daily or weekly values for synced health metrics between two dates, each with average, min, max and the usual from the 30 days before the range. Metrics: resting_hr, hrv, heart_rate, respiratory_rate, spo2, wrist_temp, steps, active_kcal, resting_kcal, exercise_min, stand_hours, distance_km, flights, daylight_min, walking_hr, vo2max, weight_kg, body_fat_pct, sleep_h, bedtime, deep_h, rem_h. For trends: 'is my resting heart rate going up', 'weight this month', 'steps vs last month'.",
    inputSchema: z.object({ metrics: z.array(z.string().min(1).max(60)).min(1).max(8), from: day.optional().describe("default 29 days before to"),
      to: day.optional().describe("default today"), every: z.enum(["day", "week"]).optional().describe("default day") }) },
  wrap(ctx, "get_metrics", (a: { metrics: string[]; from?: string; to?: string; every?: "day" | "week" }) => getMetrics(a.metrics, ...span(a, 30), a.every ?? "day")));

  s.registerTool("list_workouts", { title: "Workouts", annotations: READ, outputSchema: Out,
    description: "Workouts between two dates, newest first: strength sessions from the training log (sets per exercise, volume, working sets per muscle) and Apple Watch workouts (duration, heart rate, energy). A Watch workout that overlaps a strength session is shown inside it. Open one with get_workout.",
    inputSchema: z.object({ from: day.optional().describe("default 13 days before to"), to: day.optional().describe("default today") }) },
  wrap(ctx, "list_workouts", (a: { from?: string; to?: string }) => { const [f, t] = span(a, 14); return { range: `${f}..${t}`, workouts: listWorkouts(f, t) }; }));

  s.registerTool("get_workout", { title: "One workout", annotations: READ, outputSchema: Out,
    description: "One workout in full, by an id from list_workouts: every set (weight, reps, kind, RPE, time), best set and estimated 1RM per exercise, and heart rate when an Apple Watch workout overlapped it.",
    inputSchema: z.object({ id: z.string().min(1).max(80) }) },
  wrap(ctx, "get_workout", (a: { id: string }) => getWorkout(a.id)));

  s.registerTool("get_exercise_history", { title: "Exercise history", annotations: READ, outputSchema: Out,
    description: "One exercise's recent sessions (sets, best set, estimated 1RM), all-time records, and a rule-based suggestion for next time (double progression). Use before suggesting today's weights or answering 'what did I bench last time'.",
    inputSchema: z.object({ exercise: z.string().min(1).max(120).describe("name or id"), limit: z.number().int().min(1).max(20).optional().describe("sessions to return; default 5") }) },
  wrap(ctx, "get_exercise_history", (a: { exercise: string; limit?: number }) => exerciseHistory(a.exercise, a.limit)));

  s.registerTool("get_training_summary", { title: "Training summary", annotations: READ, outputSchema: Out,
    description: "Training between two dates: strength sessions and Watch workouts, working sets per muscle (warm-ups excluded), volume, new records, and days since each major muscle was last trained. For 'how was my training week', 'am I skipping legs'.",
    inputSchema: z.object({ from: day.optional().describe("default 6 days before to"), to: day.optional().describe("default today") }) },
  wrap(ctx, "get_training_summary", (a: { from?: string; to?: string }) => trainingSummary(...span(a, 7))));

  s.registerTool("find_exercises", { title: "Find exercises", annotations: READ, outputSchema: Out,
    description: "Search the exercise catalogue (about 750 public-domain exercises plus custom ones) by name or gym shorthand ('bench', 'rdl', 'ohp', 'lat pulldown'). Returns ids, equipment and muscles; pass an id to log_sets when a name is ambiguous.",
    inputSchema: z.object({ query: z.string().min(1).max(120), limit: z.number().int().min(1).max(25).optional() }) },
  wrap(ctx, "find_exercises", (a: { query: string; limit?: number }) => ({ matches: findExercises(a.query, a.limit ?? 8).map(({ score: _s, aliases, ...e }) => ({ ...e, ...(aliases.length && { aliases }) })) })));

  s.registerTool("get_freshness", { title: "Data freshness", annotations: READ, outputSchema: Out,
    description: "What health data Vitalis has and how current it is: last sync from the phone, sync days and problems in the last 7 days, the latest day for every metric, the latest workouts. Check this before saying something didn't happen.",
    inputSchema: z.object({}) },
  wrap(ctx, "get_freshness", () => freshness()));

  if (token.scope !== "write") return s;

  s.registerTool("log_sets", { title: "Log strength sets", annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false }, outputSchema: Out,
    description: "Log one or more strength-training sets. Sets join the open session whose last set was within 3 hours, else start a new one; pass session_id to choose (a new id starts a session with that id). Give each set your own id so a retry can't double-log. An unclear exercise name logs nothing and returns candidates to choose from.",
    inputSchema: z.object({ sets: z.array(SetIn).min(1).max(100), session_id: z.string().min(8).max(64).optional(), title: z.string().max(80).optional().describe("session title, e.g. 'Push'") }) },
  wrap(ctx, "log_sets", (a: { sets: z.infer<typeof SetIn>[]; session_id?: string; title?: string }) => logSets(a, `mcp:${token.name}`),
    (r) => `${(r as { logged: unknown[] }).logged.length} sets`));

  s.registerTool("edit_set", { title: "Edit or delete a set", annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false }, outputSchema: Out,
    description: "Change one logged set by id (weight, reps, kind, exercise, RPE, targets, note, time), or delete it with delete: true. restore: true brings a deleted set back.",
    inputSchema: SetIn.omit({ id: true }).partial().extend({ id: z.string().min(1).max(64), delete: z.boolean().optional(), restore: z.boolean().optional() }) },
  wrap(ctx, "edit_set", (a: Parameters<typeof editSet>[0]) => editSet(a)));

  s.registerTool("edit_workout", { title: "Edit or delete a session", annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false }, outputSchema: Out,
    description: "Rename a strength session, add notes, set when it ended (later sets then start a new session), or delete it with all its sets (restore: true brings it back). Apple Watch workouts are read-only.",
    inputSchema: z.object({ id: z.string().min(1).max(64), title: z.string().max(80).nullable().optional(), notes: z.string().max(2000).nullable().optional(),
      ended_at: when.nullable().optional(), delete: z.boolean().optional(), restore: z.boolean().optional() }) },
  wrap(ctx, "edit_workout", (a: Parameters<typeof editWorkout>[0]) => editWorkout(a)));

  s.registerTool("create_exercise", { title: "Add a custom exercise", annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false }, outputSchema: Out,
    description: "Add a custom exercise when find_exercises has nothing close. Returns the existing exercise instead if the name is taken.",
    inputSchema: z.object({ name: z.string().min(2).max(80), primary: z.array(z.enum(MUSCLES as [string, ...string[]])).min(1).max(4),
      secondary: z.array(z.enum(MUSCLES as [string, ...string[]])).max(6).optional(), equipment: z.string().max(40).optional(), aliases: z.array(z.string().max(60)).max(10).optional() }) },
  wrap(ctx, "create_exercise", (a: Parameters<typeof createExercise>[0]) => createExercise(a)));

  return s;
}

const handler = createMcpHandler((c) => buildServer(c.authInfo!.extra!.token as Token), { maxRequestBodySize: 1 << 20, onerror: (e) => console.error("mcp:", e.message) });

export async function mcpRoute(c: Context) {
  // Bearer tokens aren't sent by browsers on their own, but a page script could try: refuse foreign Origins.
  const origin = c.req.header("origin");
  if (origin && !sameHost(origin, c.req.header("host"))) return c.json({ error: "Cross-site request refused" }, 403);
  const token = authenticate(c.req.header("authorization"));
  if (!token || token.scope === "ingest") {
    if (c.req.header("authorization")) logCall(token?.id ?? null, "mcp:auth", false, 0, token ? "ingest token used on /mcp" : "bad or revoked token");
    return bearerAuthChallengeResponse(new OAuthError(OAuthErrorCode.InvalidToken, token ? "This token can only push data to /ingest" : "Missing or invalid token"));
  }
  return handler.fetch(c.req.raw, { authInfo: { token: "", clientId: token.id, scopes: [token.scope], extra: { token } } });
}
function sameHost(origin: string, host: string | undefined) {
  try { const h = new URL(origin).host; return h === host || (!!HOST && h === HOST); } catch { return false; }
}
