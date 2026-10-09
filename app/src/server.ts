// One process: /ingest for the phone, /mcp for agents, /health for the proxy. No UI, no cookies.
import { serve } from "@hono/node-server";
import { Hono } from "hono";
import { fileURLToPath } from "node:url";
import { BIND, HttpError, MAX_INGEST_BYTES, PORT } from "./config.js";
import { seedExercises } from "./exercises.js";
import { ingest } from "./ingest.js";
import { mcpRoute } from "./mcp.js";
import { authenticate, logCall } from "./tokens.js";

seedExercises();

export const app = new Hono();

app.get("/health", (c) => c.json({ ok: true }));

// Health Auto Export's REST automation. ingest tokens (or write tokens) only; the phone gets 200 once the raw body is stored.
app.post("/ingest", async (c) => {
  const t0 = Date.now();
  const token = authenticate(c.req.header("authorization"));
  if (!token || token.scope === "read") return c.json({ error: token ? "This token can't push data; use an ingest token" : "Missing or invalid token" }, 401);
  if (Number(c.req.header("content-length") ?? 0) > MAX_INGEST_BYTES) return c.json({ error: `Body over ${MAX_INGEST_BYTES >> 20} MB; turn on Batch Requests` }, 413);
  const body = Buffer.from(await c.req.arrayBuffer());
  if (body.length > MAX_INGEST_BYTES) return c.json({ error: `Body over ${MAX_INGEST_BYTES >> 20} MB; turn on Batch Requests` }, 413);
  try {
    const r = ingest(body, { origin: `rest:${token.name}`, automation: c.req.header("automation-name") ?? c.req.header("automation-id") ?? null,
      aggregation: c.req.header("automation-aggregation") ?? null, period: c.req.header("automation-period") ?? null });
    logCall(token.id, "ingest", true, Date.now() - t0, `${body.length} bytes, ${JSON.stringify(r.counts)}${r.duplicate ? ", duplicate" : ""}${r.warnings.length ? `, ${r.warnings.length} warnings` : ""}`);
    return c.json(r);
  } catch (e) {
    const err = e as HttpError;
    logCall(token.id, "ingest", false, Date.now() - t0, err.message.slice(0, 200));
    if (err instanceof HttpError) return c.json({ error: err.message }, err.status as 400);
    console.error("ingest failed:", err);
    return c.json({ error: "Ingest failed; see the server log" }, 500);
  }
});

app.all("/mcp", mcpRoute);

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  serve({ fetch: app.fetch, port: PORT, hostname: BIND }, (i) => console.log(`vitalis listening on ${BIND}:${i.port}`));
}
