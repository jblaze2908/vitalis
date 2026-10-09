// Shared harness: a fresh VITALIS_ROOT per test file (node --test runs each file in its own process), the Hono app
// called in-process, and a generator for synthetic Health Auto Export payloads. No real health data lives in this repo.
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

process.env.VITALIS_ROOT = mkdtempSync(join(tmpdir(), "vitalis-test-"));
process.env.VITALIS_TZ = "Asia/Kolkata";
process.env.VITALIS_HOST = "vitalis.example.com";

export const { app } = await import("../dist/src/server.js");
export const tokens = await import("../dist/src/tokens.js");
export const { ingest } = await import("../dist/src/ingest.js");
export const { one, all } = await import("../dist/src/db.js");

export const addDays = (day, n) => { const d = new Date(`${day}T00:00:00Z`); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
const at = (day, hm) => `${day} ${hm}:00 +0530`;

/**
 * Daily-aggregated payload in Health Auto Export's v2 JSON shape, one entry per day from `from` for `n` days.
 * `f(i, day)` returns overrides: { rhr, hrv, steps, sleepH, bed: "23:30", weight }.
 */
export function payload(from, n, f = () => ({})) {
  const days = Array.from({ length: n }, (_, i) => [i, addDays(from, i)]);
  const v = (i, d) => ({ rhr: 60, hrv: 50, steps: 6000, sleepH: 7, bed: "23:30", resp: 15, kj: 1600, weight: 80, ...f(i, d) });
  const m = (name, units, row) => ({ name, units, data: days.map(([i, d]) => row(v(i, d), d)).filter(Boolean) });
  return { data: {
    metrics: [
      m("resting_heart_rate", "count/min", (x, d) => x.rhr == null ? null : { date: at(d, "00:00"), qty: x.rhr, source: "Test Watch" }),
      m("heart_rate_variability", "ms", (x, d) => x.hrv == null ? null : { date: at(d, "00:00"), qty: x.hrv, source: "Test Watch" }),
      m("respiratory_rate", "count/min", (x, d) => ({ date: at(d, "00:00"), qty: x.resp, source: "Test Watch" })),
      m("step_count", "count", (x, d) => ({ date: at(d, "00:00"), qty: x.steps, source: "" })),
      m("active_energy", "kJ", (x, d) => ({ date: at(d, "00:00"), qty: x.kj, source: "" })),
      m("heart_rate", "count/min", (x, d) => ({ date: at(d, "00:00"), Min: 50, Avg: 75, Max: 150 })),
      m("weight_body_mass", "kg", (x, d) => x.weight == null ? null : { date: at(d, "00:00"), qty: x.weight, source: "Health" }),
      m("sleep_analysis", "hr", (x, d) => {
        if (x.sleepH == null) return null;
        const [h, mi] = x.bed.split(":").map(Number);
        const startDay = h >= 18 ? addDays(d, -1) : d;
        const endMin = h * 60 + mi + Math.round(x.sleepH * 60 + 20);
        const end = `${String(Math.floor(endMin / 60) % 24).padStart(2, "0")}:${String(endMin % 60).padStart(2, "0")}`;
        return { date: at(d, "00:00"), source: "Test Watch", sleepStart: at(startDay, x.bed), sleepEnd: at(d, end), inBedStart: at(startDay, x.bed), inBedEnd: at(d, end),
          core: x.sleepH * 0.6, deep: x.sleepH * 0.15, rem: x.sleepH * 0.25, awake: 0.3, totalSleep: 0, inBed: 0, asleep: 0 };
      }),
    ],
    workouts: [],
  } };
}

export const body = (p) => Buffer.from(JSON.stringify(p));

export async function http(method, path, { token, json, raw, headers = {} } = {}) {
  const h = { ...headers };
  if (token) h.authorization = `Bearer ${token}`;
  if (json !== undefined || raw !== undefined) h["content-type"] = "application/json";
  const r = await app.request(path, { method, headers: h, body: raw ?? (json === undefined ? undefined : JSON.stringify(json)) });
  const text = await r.text();
  let data = null; try { data = JSON.parse(text); } catch {}
  return { status: r.status, json: data, text };
}

let id = 0;
export async function mcp(token, method, params = {}) {
  const headers = { accept: "application/json, text/event-stream", "mcp-protocol-version": "2025-06-18" };
  const r = await http("POST", "/mcp", { token, headers, json: { jsonrpc: "2.0", id: ++id, method, params } });
  if (r.status !== 200) return r;
  const msg = r.json ?? r.text.split("\n").filter((l) => l.startsWith("data:")).map((l) => JSON.parse(l.slice(5))).find((m) => m.id === id);
  return { status: 200, msg };
}
export async function call(token, name, args = {}) {
  const r = await mcp(token, "tools/call", { name, arguments: args });
  if (r.status !== 200) throw new Error(`${name}: HTTP ${r.status} ${r.text}`);
  const res = r.msg.result;
  return { isError: !!res.isError, data: res.structuredContent, text: res.content?.[0]?.text };
}
