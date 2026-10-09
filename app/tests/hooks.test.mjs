import { test } from "node:test";
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
  srv.close();
});
