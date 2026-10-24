// One process: /ingest and /v2 for phones, /mcp for agents, /health for the proxy. No UI, no cookies.
import { serve } from "@hono/node-server";
import { Hono } from "hono";
import { fileURLToPath } from "node:url";
import { BIND, HttpError, MAX_INGEST_BYTES, PORT } from "./config.js";
import { seedExercises } from "./exercises.js";
import { afterIngest } from "./hooks.js";
import { ingest } from "./ingest.js";
import { mcpRoute } from "./mcp.js";
import { authenticate, logCall } from "./tokens.js";
import { ingestV2Async } from "./v2-client.js";
import { syncStatus } from "./v2.js";

seedExercises();

export const app = new Hono();

app.get("/health", (c) => c.json({ ok: true }));

// Health Auto Export's REST automation. ingest tokens (or write tokens) only; the phone gets 200 once the raw body is stored.
app.post("/ingest", async (c) => {
  const t0 = Date.now();
  const token = authenticate(c.req.header("authorization") ?? c.req.header("x-api-key"));
  if (!token || token.scope === "read") return c.json({ error: token ? "This token can't push data; use an ingest token" : "Missing or invalid token" }, 401);
  if (Number(c.req.header("content-length") ?? 0) > MAX_INGEST_BYTES) return c.json({ error: `Body over ${MAX_INGEST_BYTES >> 20} MB; turn on Batch Requests` }, 413);
  const body = Buffer.from(await c.req.arrayBuffer());
  if (body.length > MAX_INGEST_BYTES) return c.json({ error: `Body over ${MAX_INGEST_BYTES >> 20} MB; turn on Batch Requests` }, 413);
  try {
    const r = ingest(body, { origin: `rest:${token.name}`, automation: c.req.header("automation-name") ?? c.req.header("automation-id") ?? null,
      aggregation: c.req.header("automation-aggregation") ?? null, period: c.req.header("automation-period") ?? null });
    logCall(token.id, "ingest", true, Date.now() - t0, `${body.length} bytes, ${JSON.stringify(r.counts)}${r.duplicate ? ", duplicate" : ""}${r.warnings.length ? `, ${r.warnings.length} warnings` : ""}`);
    void afterIngest(r.new_nights);
    const { new_nights: _n, ...out } = r;
    return c.json(out);
  } catch (e) {
    const err = e as HttpError;
    logCall(token.id, "ingest", false, Date.now() - t0, err.message.slice(0, 200));
    if (err instanceof HttpError) return c.json({ error: err.message }, err.status as 400);
    console.error("ingest failed:", err);
    return c.json({ error: "Ingest failed; see the server log" }, 500);
  }
});

app.post("/v2/samples", async (c) => {
  const t0 = Date.now();
  const token = authenticate(c.req.header("authorization") ?? c.req.header("x-api-key"));
  if (!token || token.scope === "read") return c.json({ error: token ? "This token can't push data; use an ingest token" : "Missing or invalid token" }, 401);
  try {
    if (Number(c.req.header("content-length") ?? 0) > MAX_INGEST_BYTES) throw new HttpError(413, "Body exceeds ingest size limit");
    const encoding = c.req.header("content-encoding")?.trim().toLowerCase();
    if (encoding && encoding !== "identity" && encoding !== "gzip") throw new HttpError(415, "Unsupported Content-Encoding");
    // Bound the wire body while reading, including requests without Content-Length.
    const chunks: Uint8Array[] = []; let size = 0;
    const reader = c.req.raw.body?.getReader();
    if (reader) {
      try {
        for (;;) {
          const { done, value } = await reader.read(); if (done) break;
          size += value.length;
          if (size > MAX_INGEST_BYTES) { await reader.cancel(); throw new HttpError(413, "Body exceeds ingest size limit"); }
          chunks.push(value);
        }
      } finally { reader.releaseLock(); }
    }
    const body = Buffer.concat(chunks), bodyBytes = body.length;
    const r = await ingestV2Async(body, encoding);
    logCall(token.id, "v2/samples", true, Date.now() - t0, `${bodyBytes} bytes, ${JSON.stringify(r.counts)}${r.duplicate ? ", duplicate" : ""}`);
    const { new_nights: _n, ...out } = r;
    return c.json(out);
  } catch (e) {
    const err = e as Error;
    logCall(token.id, "v2/samples", false, Date.now() - t0, err.message.slice(0, 200));
    if (err instanceof HttpError) return c.json({ error: err.message }, err.status as 400);
    console.error("v2 ingest failed:", err);
    return c.json({ error: "Ingest failed; see the server log" }, 500);
  }
});

app.get("/v2/sync/status", (c) => {
  const token = authenticate(c.req.header("authorization") ?? c.req.header("x-api-key"));
  if (!token) return c.json({ error: "Missing or invalid token" }, 401);
  return c.json(syncStatus());
});

app.all("/mcp", mcpRoute);

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  serve({ fetch: app.fetch, port: PORT, hostname: BIND }, (i) => console.log(`vitalis listening on ${BIND}:${i.port}`));
}
