import { test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { addDays, body, http, ingest, one, all, payload, tokens } from "./_env.mjs";
import { bodyDay } from "../dist/src/weight.js";
import { today } from "../dist/src/time.js";

const read = tokens.createToken("body read", "read").token;
const write = tokens.createToken("body write", "write").token;
const ingestTok = tokens.createToken("body ingest", "ingest").token;
const T = today(), Y = addDays(T, -1);
ingest(body(payload(addDays(T, -40), 39, (i) => ({ weight: 78 - i * 0.05, hrv: 50 + (i % 5), rhr: 58 + (i % 3) }))), { origin: "test" });

test("posting the same weight id twice leaves one entry; a changed body updates it; latest source is VITALIS", async () => {
  const entry = { id: "W1", kg: 76.6, measured_at: `${T}T07:05:00+05:30` };
  const a = await http("POST", "/v2/weight", { token: write, json: entry });
  assert.equal(a.status, 200, a.text);
  assert.deepEqual(a.json.entry, { id: "W1", kg: 76.6, day: T });
  assert.equal(a.json.weight.latest.source, "VITALIS"); assert.equal(a.json.weight.latest.manual, true);
  assert.equal(a.json.weight.latest.at, `${T}T07:05:00+05:30`);
  await http("POST", "/v2/weight", { token: write, json: entry });
  assert.equal(one("SELECT COUNT(*) n FROM weight_entries").n, 1);
  const b = await http("POST", "/v2/weight", { token: write, json: { ...entry, kg: 76.4 } });
  assert.equal(b.json.weight.latest.kg, 76.4);
  assert.equal(one("SELECT qty FROM metric_days WHERE metric='weight_kg' AND day=? AND source='Vitalis manual'", T).qty, 76.4);
});

test("a manual entry and a HealthKit sample with the same value on the same day give one daily value", async () => {
  await http("POST", "/v2/weight", { token: write, json: { id: "W2", kg: 77.1, measured_at: `${Y}T07:00:00+05:30`, hk_uuid: "HK-W2" } });
  const r = await http("POST", "/v2/samples", { token: ingestTok, json: { schema: 1, batch_id: randomUUID(), client: { install_id: "t", app_version: "0", os: "iOS", model: "T" },
    upserts: [{ uuid: "HK-W2", type: "HKQuantityTypeIdentifierBodyMass", kind: "quantity", start: `${Y}T07:00:00.000+05:30`, end: `${Y}T07:00:00.000+05:30`,
      source: { name: "Vitalis", bundle_id: "app.vitalis", version: "1", os_version: "26" }, value: 77.1, unit: "kg" }], deletions: [], daily_stats: [] } });
  assert.equal(r.status, 200, r.text);
  assert.equal(all("SELECT source FROM metric_days WHERE metric='weight_kg' AND day=?", Y).length >= 2, true, "both sources stored");
  const s = bodyDay(T).weight.series.find((p) => p.day === Y);
  assert.equal(s.raw_kg, 77.1);
});

test("delete removes the entry from reads and re-projects the day; unknown id is 404", async () => {
  await http("POST", "/v2/weight", { token: write, json: { id: "W3", kg: 75, measured_at: `${addDays(T, -2)}T08:00:00+05:30` } });
  const d = await http("DELETE", "/v2/weight/W3", { token: write });
  assert.equal(d.status, 200);
  assert.equal(one("SELECT * FROM metric_days WHERE metric='weight_kg' AND day=? AND source='Vitalis manual'", addDays(T, -2)), undefined);
  assert.equal((await http("DELETE", "/v2/weight/W3", { token: write })).status, 200, "deleting twice is fine");
  assert.equal((await http("DELETE", "/v2/weight/nope", { token: write })).status, 404);
  assert.equal((await http("POST", "/v2/weight", { token: read, json: { id: "x", kg: 70, measured_at: `${T}T07:00:00+05:30` } })).status, 403);
  assert.equal((await http("POST", "/v2/weight", { token: write, json: { id: "x", kg: 0, measured_at: `${T}T07:00:00+05:30` } })).status, 422);
});

test("GET /v2/body: 30-day series with trend, activity week, vitals against the usual", async () => {
  const r = await http("GET", "/v2/body", { token: read });
  assert.equal(r.status, 200, r.text);
  const b = r.json;
  assert.equal(b.weight.series.length, 30); assert.equal(b.weight.series.at(-1).day, T);
  assert.ok(b.weight.trend_kg > 75 && b.weight.trend_kg < 79); assert.equal(typeof b.weight.month_change_kg, "number");
  assert.equal(b.activity.week.length, 7);
  assert.deepEqual(b.vitals.map((v) => v.key), ["hrv", "resting_hr", "spo2", "respiratory_rate"]);
  const day = addDays(T, -2), past = bodyDay(day);
  assert.equal(past.vitals[0].value !== null, true); assert.ok(past.vitals[0].usual !== null);
  assert.equal(past.vitals[3].reading, null, "breathing is neutral");
});
