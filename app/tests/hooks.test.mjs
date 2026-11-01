import { after, test } from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { createHmac, randomBytes } from "node:crypto";

// A local receiver that checks signatures the way Pitcrew's hooks.ts does (Standard Webhooks).
const secret = `whsec_${randomBytes(32).toString("base64")}`;
const got = [];
const srv = createServer((req, res) => {
  let b = ""; req.on("data", (c) => (b += c)); req.on("end", () => {
    const want = createHmac("sha256", Buffer.from(secret.slice(6), "base64")).update(`${req.headers["webhook-id"]}.${req.headers["webhook-timestamp"]}.`).update(b).digest("base64");
    got.push({ ok: req.headers["webhook-signature"] === `v1,${want}`, body: JSON.parse(b) });
    res.end("ok");
  });
});
await new Promise((ok) => srv.listen(0, "127.0.0.1", ok));
process.env.VITALIS_HOOK_URL = `http://127.0.0.1:${srv.address().port}/api/hooks/sc_test`;
process.env.VITALIS_HOOK_SECRET = secret;
const { addDays, body, http, payload, tokens } = await import("./_env.mjs");
const { today } = await import("../dist/src/time.js");
const { one, run } = await import("../dist/src/db.js");
const tok = tokens.createToken("phone", "ingest").token;
const wait = (ms) => new Promise((ok) => setTimeout(ok, ms));

test("sleep.ready fires once when today's night first arrives; old nights and re-sends don't fire it", async () => {
  const day = today();
  await http("POST", "/ingest", { token: tok, raw: body(payload(addDays(day, -10), 5)) });
  await wait(200);
  assert.equal(got.length, 0, "a backfill of old nights is silent");
  await http("POST", "/ingest", { token: tok, raw: body(payload(day, 1)) });
  await wait(300);
  assert.equal(got.length, 1);
  assert.equal(got[0].ok, true, "signature verifies with the receiver's secret");
  assert.deepEqual({ type: got[0].body.type, day: got[0].body.day }, { type: "sleep.ready", day });
  await http("POST", "/ingest", { token: tok, raw: body(payload(day, 1, () => ({ steps: 9000 }))) });
  await wait(300);
  assert.equal(got.length, 1, "later pushes the same day stay silent");
});

test("a sleep.ready that never got through is retried by the next push that day, even when the night isn't new", async () => {
  const day = today();
  run("UPDATE hook_events SET sent_at=NULL,status='ECONNREFUSED',claimed_at=NULL WHERE event='sleep.ready' AND day=?", day);
  const before = got.length;
  await http("POST", "/ingest", { token: tok, raw: body(payload(day, 1, () => ({ steps: 9500 }))) });
  await wait(300);
  assert.equal(got.length, before + 1, "the pending event is delivered");
  assert.ok(one("SELECT sent_at FROM hook_events WHERE event='sleep.ready' AND day=?", day).sent_at);
  await http("POST", "/ingest", { token: tok, raw: body(payload(day, 1, () => ({ steps: 9900 }))) });
  await wait(300);
  assert.equal(got.length, before + 1, "and not again once delivered");
});

test("a live claim stops a second delivery of the same event", async () => {
  const day = today();
  run("UPDATE hook_events SET sent_at=NULL,claimed_at=? WHERE event='sleep.ready' AND day=?", Date.now(), day);
  const before = got.length;
  await http("POST", "/ingest", { token: tok, raw: body(payload(day, 1, () => ({ steps: 10100 }))) });
  await wait(300);
  assert.equal(got.length, before, "another push is already delivering it");
});

after(() => srv.close());
