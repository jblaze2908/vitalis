import { test } from "node:test";
import assert from "node:assert/strict";
import { z } from "zod";
import { app, http, one, tokens } from "./_env.mjs";
import { ApiError, dayParam, handle, readJson, routeKey, withEtag } from "../dist/src/http.js";
import { bumpDataVersion, bumpTargetsVersion } from "../dist/src/db.js";

let computed = 0;
// Registered before the first request: Hono builds its matcher lazily.
app.get("/test/thing", handle("test_get", "read", (c) => withEtag(c, routeKey(c), () => ({ n: ++computed, day: dayParam(c) }))));
app.post("/test/thing", handle("test_post", "write", async (c) => c.json(await readJson(c, z.object({ kg: z.number().min(1) })))));
app.get("/test/boom", handle("test_boom", "read", () => { throw new Error("secret internal detail"); }));
app.get("/test/missing", handle("test_missing", "read", () => { throw new ApiError(404, "No such thing"); }));

const ingest = tokens.createToken("http ingest", "ingest").token;
const read = tokens.createToken("http read", "read").token;
const write = tokens.createToken("http write", "write").token;

test("scopes: missing token 401, ingest 403 on GET, read 403 on POST, write allowed", async () => {
  let r = await http("GET", "/test/thing");
  assert.equal(r.status, 401); assert.deepEqual(r.json, { error: "Missing or invalid token", code: "unauthorized" });
  r = await http("GET", "/test/thing", { token: ingest });
  assert.equal(r.status, 403); assert.equal(r.json.code, "scope");
  assert.equal((await http("GET", "/test/thing", { token: read })).status, 200);
  r = await http("POST", "/test/thing", { token: read, json: { kg: 2 } });
  assert.equal(r.status, 403); assert.equal(r.json.code, "scope"); assert.match(r.json.error, /write token/);
  r = await http("POST", "/test/thing", { token: write, json: { kg: 2 } });
  assert.equal(r.status, 200); assert.deepEqual(r.json, { kg: 2 });
});

test("ETag: a repeated GET with If-None-Match is 304 with no body and no compute; a version bump changes it", async () => {
  const a = await app.request("/test/thing?b=2&a=1", { headers: { authorization: `Bearer ${read}` } });
  const etag = a.headers.get("etag");
  assert.equal(a.status, 200); assert.match(etag, /^W\/".+"$/); assert.equal(a.headers.get("cache-control"), "private, no-cache");
  const before = computed;
  const b = await app.request("/test/thing?a=1&b=2", { headers: { authorization: `Bearer ${read}`, "if-none-match": etag } });
  assert.equal(b.status, 304); assert.equal(await b.text(), ""); assert.equal(computed, before, "nothing computed for a 304");
  bumpDataVersion();
  const c = await app.request("/test/thing?a=1&b=2", { headers: { authorization: `Bearer ${read}`, "if-none-match": etag } });
  assert.equal(c.status, 200); assert.notEqual(c.headers.get("etag"), etag);
  const d = c.headers.get("etag"); bumpTargetsVersion();
  const e = await app.request("/test/thing?a=1&b=2", { headers: { authorization: `Bearer ${read}`, "if-none-match": d } });
  assert.equal(e.status, 200);
});

test("bodies: 400 not JSON, 422 names the field, 413 over 1 MB", async () => {
  let r = await http("POST", "/test/thing", { token: write, raw: "{nope" });
  assert.equal(r.status, 400); assert.equal(r.json.code, "bad_request");
  r = await http("POST", "/test/thing", { token: write, json: { kg: 0 } });
  assert.equal(r.status, 422); assert.equal(r.json.code, "invalid"); assert.match(r.json.error, /^kg: /);
  r = await http("POST", "/test/thing", { token: write, raw: JSON.stringify({ kg: 2, pad: "x".repeat(1 << 20) }) });
  assert.equal(r.status, 413); assert.equal(r.json.code, "too_large");
});

test("errors: unknown errors are a generic 500; domain errors keep status and code; dates are checked", async () => {
  const orig = console.error; console.error = () => {};
  let r; try { r = await http("GET", "/test/boom", { token: read }); } finally { console.error = orig; }
  assert.equal(r.status, 500); assert.equal(r.json.code, "internal"); assert.doesNotMatch(r.text, /secret/);
  r = await http("GET", "/test/missing", { token: read });
  assert.equal(r.status, 404); assert.deepEqual(r.json, { error: "No such thing", code: "not_found" });
  assert.equal((await http("GET", "/test/thing?date=2026-1-1", { token: read })).status, 400);
  assert.equal((await http("GET", "/test/thing?date=2999-01-01", { token: read })).status, 400);
  assert.equal((await http("GET", "/test/thing?date=2026-10-01", { token: read })).json.day, "2026-10-01");
  const call = one("SELECT tool,ok,detail FROM calls WHERE tool='test_missing' ORDER BY id DESC LIMIT 1");
  assert.equal(call.ok, 0);
});

test("/v2/sync/status reports what each token can do, plus server version and time zone", async () => {
  const expect = { [ingest]: [true, false, false], [read]: [false, true, false], [write]: [true, true, true] };
  for (const [tok, [push, rd, wr]] of Object.entries(expect)) {
    const r = await http("GET", "/v2/sync/status", { token: tok });
    assert.equal(r.status, 200);
    assert.deepEqual([r.json.token.can_push, r.json.token.can_read, r.json.token.can_write], [push, rd, wr]);
    assert.equal(r.json.server.tz, "Asia/Kolkata"); assert.match(r.json.server.time, /\+05:30$/);
    assert.equal(r.json.server.version, "0.1.0");
  }
});
