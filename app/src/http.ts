// Shared plumbing for the app's JSON routes: scope checks, error bodies, ETag/304, bounded zod bodies, date params.
// Every call is audited through logCall with counts only, never values.
import { createHash } from "node:crypto";
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { Context } from "hono";
import type { z } from "zod";
import { HttpError } from "./config.js";
import { dataVersions } from "./db.js";
import { addDays, DAY_RE, ownerOffsetMin, today } from "./time.js";
import { authenticate, logCall, type Token } from "./tokens.js";

export const MAX_BODY_BYTES = 1 << 20;

const CODES: Record<number, string> = { 400: "bad_request", 401: "unauthorized", 403: "scope", 404: "not_found", 409: "conflict",
  413: "too_large", 422: "invalid", 429: "rate_limited", 502: "describe_failed", 503: "unavailable", 504: "describe_timeout" };

/** An HttpError with an explicit `code` and extra body fields (e.g. 422 candidates). */
export class ApiError extends HttpError {
  constructor(status: number, message: string, public code?: string, public extra?: Record<string, unknown>) { super(status, message); }
}

export function jsonError(c: Context, status: number, error: string, code?: string, extra?: Record<string, unknown>) {
  return c.json({ error, code: code ?? CODES[status] ?? "error", ...extra }, status as 400);
}

export function requireToken(c: Context, need: "read" | "write"): Token {
  const token = authenticate(c.req.header("authorization") ?? c.req.header("x-api-key"));
  if (!token) throw new ApiError(401, "Missing or invalid token", "unauthorized");
  if (need === "read" && token.scope === "ingest") throw new ApiError(403, "This token can't read; use a read or write token", "scope");
  if (need === "write" && token.scope !== "write") throw new ApiError(403, "This token can't change data; use a write token", "scope");
  return token;
}

const details = new WeakMap<Context, string>();
/** Audit detail for this call: counts only. */
export const setDetail = (c: Context, detail: string) => { details.set(c, detail); };

/** A route body with auth, timing, audit and error mapping. Unknown errors never leak their message. */
export function handle(name: string, need: "read" | "write", fn: (c: Context, token: Token) => Response | Promise<Response>) {
  return async (c: Context) => {
    const t0 = Date.now();
    let token: Token | null = null;
    try {
      token = requireToken(c, need);
      const res = await fn(c, token);
      logCall(token.id, name, true, Date.now() - t0, details.get(c) ?? null);
      return res;
    } catch (e) {
      const err = e as Error;
      const known = err instanceof HttpError && err.status < 500 || err instanceof ApiError;
      if (!known) console.error(`${name} failed:`, err);
      if (token || (err instanceof HttpError && err.status !== 401)) logCall(token?.id ?? null, name, false, Date.now() - t0, known ? err.message.slice(0, 200) : "internal error");
      if (err instanceof ApiError) return jsonError(c, err.status, err.message, err.code, err.extra);
      if (err instanceof HttpError && err.status < 500) return jsonError(c, err.status, err.message);
      return jsonError(c, 500, "Vitalis couldn't do that; see the server log", "internal");
    }
  };
}

const CLOCK_BUCKET_MS = 15 * 60_000;
/**
 * Hash of the server's own compiled code, read once at start. A deploy that changes a body's shape must not be answered
 * 304 from the phone's cache just because no health data changed; scale-to-zero restarts keep the same value.
 */
const BUILD = (() => {
  const h = createHash("sha1");
  const walk = (dir: string) => {
    for (const e of readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
      if (e.isDirectory()) walk(join(dir, e.name)); else if (e.name.endsWith(".js")) h.update(readFileSync(join(dir, e.name)));
    }
  };
  walk(dirname(fileURLToPath(import.meta.url)));
  return h.digest("base64url").slice(0, 8);
})();
/** Weak ETag from the build, the meta versions and the route key; `clock` adds the local 15-minute bucket for bodies that read the time. */
export function etagFor(routeKey: string, clock = false, now = Date.now()) {
  const v = dataVersions();
  const bucket = clock ? `|${Math.floor((now + ownerOffsetMin(now) * 60_000) / CLOCK_BUCKET_MS)}` : "";
  return `W/"${BUILD}.${v.data}.${v.targets}.${createHash("sha1").update(routeKey + bucket).digest("base64url").slice(0, 16)}"`;
}

/** 304 before computing anything when If-None-Match matches; otherwise compute and send JSON with the ETag. */
export async function withEtag(c: Context, routeKey: string, compute: () => unknown | Promise<unknown>, opts: { clock?: boolean; now?: number } = {}) {
  const etag = etagFor(routeKey, opts.clock, opts.now);
  const headers = { ETag: etag, "Cache-Control": "private, no-cache" };
  const inm = c.req.header("if-none-match");
  if (inm && inm.split(",").map((s) => s.trim()).some((t) => t === etag || t === "*")) return c.body(null, 304, headers);
  return c.json(await compute() as object, 200, headers);
}

/** Route key = path plus sorted query, so `?a=1&b=2` and `?b=2&a=1` share an ETag. */
export function routeKey(c: Context) {
  const url = new URL(c.req.url);
  const q = [...url.searchParams].sort(([a], [b]) => a.localeCompare(b)).map(([k, v]) => `${k}=${v}`).join("&");
  return `${url.pathname}?${q}`;
}

/** Parse a JSON body (≤ 1 MB) against a zod schema: 413 too big, 400 not JSON, 422 naming the first bad field. */
export async function readJson<S extends z.ZodType>(c: Context, schema: S): Promise<z.infer<S>> {
  if (Number(c.req.header("content-length") ?? 0) > MAX_BODY_BYTES) throw new ApiError(413, "Body over 1 MB", "too_large");
  const chunks: Uint8Array[] = []; let size = 0;
  const reader = c.req.raw.body?.getReader();
  if (reader) {
    try {
      for (;;) {
        const { done, value } = await reader.read(); if (done) break;
        size += value.length;
        if (size > MAX_BODY_BYTES) { await reader.cancel(); throw new ApiError(413, "Body over 1 MB", "too_large"); }
        chunks.push(value);
      }
    } finally { reader.releaseLock(); }
  }
  let json: unknown;
  try { json = JSON.parse(Buffer.concat(chunks).toString("utf8")); } catch { throw new ApiError(400, "Body is not JSON", "bad_request"); }
  const r = schema.safeParse(json);
  if (!r.success) {
    const i = r.error.issues[0];
    throw new ApiError(422, `${i.path.length ? i.path.join(".") : "body"}: ${i.message}`, "invalid");
  }
  return r.data;
}

/** A local-day query param, default today; malformed or more than a day ahead is 400. */
export function dayParam(c: Context, name = "date", now = Date.now()) {
  const raw = c.req.query(name);
  const t = today(now);
  if (raw === undefined || raw === "") return t;
  if (!DAY_RE.test(raw) || Number.isNaN(Date.parse(`${raw}T00:00:00Z`))) throw new ApiError(400, `${name} must be a date like 2026-10-24`, "bad_request");
  if (raw > addDays(t, 1)) throw new ApiError(400, `${name} is more than a day in the future`, "bad_request");
  return raw;
}
