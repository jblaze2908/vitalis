import { test } from "node:test";
import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { gzipSync, gunzipSync } from "node:zlib";
import { spawnSync } from "node:child_process";
import { all, body, http, one, tokens } from "./_env.mjs";
import { decodePayload } from "../dist/src/v2-payload.js";
import { blobFor, unpack } from "../dist/src/v2-storage.js";
import { db, run } from "../dist/src/db.js";
import { reparse } from "../dist/src/ingest.js";
import { freshness, freshFor } from "../dist/src/health.js";

const ingestToken = tokens.createToken("native phone", "ingest").token;
const writeToken = tokens.createToken("native writer", "write").token;
const readToken = tokens.createToken("native reader", "read").token;
const type = (s) => `HKQuantityTypeIdentifier${s}`;
const at = (day, hm) => `${day}T${hm}:00.123+05:30`;
const sample = (props = {}) => ({ uuid: randomUUID(), type: type("StepCount"), kind: "quantity", start: at("2026-10-01", "10:00"),
  end: at("2026-10-01", "10:10"), source: { name: "Native Watch", bundle_id: "com.apple.health", version: "1", os_version: "26" },
  value: 100, unit: "count", ...props });
const batch = (upserts = [], props = {}) => ({ schema: 1, batch_id: randomUUID(), client: { install_id: "test", app_version: "0.1", os: "iOS 26", model: "Test" },
  upserts, deletions: [], daily_stats: [], ...props });
const post = (b, options = {}) => http("POST", "/v2/samples", { token: ingestToken, json: b, ...options });
const payloadId = (id) => one("SELECT payload_id FROM hk_batches WHERE batch_id=?", id).payload_id;
const row = (s) => one("SELECT * FROM hk_raw WHERE uuid=?", s.uuid);
const points = s => { const b = blobFor(s.uuid); return b ? unpack(b) : []; };
const metric = (key, day, source = "Native Watch") => one("SELECT * FROM metric_days WHERE metric=? AND day=? AND source=?", key, day, source);
const sleep = (value, day, start, end, props = {}) => sample({ type: "HKCategoryTypeIdentifierSleepAnalysis", kind: "category", value,
  value_label: ["inBed", "asleepUnspecified", "awake", "asleepCore", "asleepDeep", "asleepREM"][value], start: at(day, start), end: at(day, end), ...props });
const workout = (props = {}) => sample({ type: "HKWorkoutTypeIdentifier", kind: "workout", activity_type: 50, activity_name: "traditionalStrengthTraining",
  duration_s: 600, events: [], activities: [], statistics: {}, ...props });

test("insert, unchanged content, UUID replacement, duplicate batch id and lossless raw body", async () => {
  const s = sample({ metadata: { date: at("2026-10-01", "10:00"), quantity: { value: 1.23456789, unit: "kg" } },
    device: { name: null, model: "Watch" }, future_field: { a: [1, null, "x"] } });
  const b = batch([s]), a = await post(b);
  assert.equal(a.status, 200, a.text);
  assert.deepEqual(a.json.counts, { inserted: 1, updated: 0, unchanged: 0, deleted: 0, daily_stats: 0, rejected: 0 });
  assert.equal(row(s).start_ms, Date.parse(s.start));
  assert.deepEqual(JSON.parse(row(s).metadata_json), s.metadata);
  assert.deepEqual(JSON.parse(row(s).extra_json).future_field, s.future_field);
  const p = one("SELECT body_gz,origin,codec FROM payloads WHERE id=?", payloadId(b.batch_id));
  assert.deepEqual(JSON.parse(decodePayload(p.body_gz, p.codec)), b); assert.equal(p.origin, "v2");
  const same = await post(batch([Object.fromEntries(Object.entries(s).reverse())]));
  assert.equal(same.json.counts.unchanged, 1);
  assert.equal((await post(batch([{ ...s, value: 110 }]))).json.counts.updated, 1);
  assert.equal(row(s).value, 110); assert.equal(metric("steps", "2026-10-01").qty, 110);
  for (const repeated of [b]) {
    const dup = await post(repeated);
    assert.equal(dup.status, 200); assert.equal(dup.json.duplicate, true);
    assert.deepEqual(dup.json.counts, a.json.counts); assert.equal(row(s).value, 110);
  }
});

test("deletion before and after upsert is permanent; repeated tombstones do not count twice", async () => {
  for (const before of [true, false]) {
    const day = before ? "2026-10-02" : "2026-10-03";
    const s = sample({ start: at(day, "10:00"), end: at(day, "10:10") });
    const d = { uuid: s.uuid, type: s.type };
    if (!before) await post(batch([s]));
    assert.equal((await post(batch([], { deletions: [d] }))).json.counts.deleted, 1);
    assert.equal((await post(batch([], { deletions: [d] }))).json.counts.deleted, 0);
    await post(batch([s])); await post(batch([{ ...s, value: 10000 }]));
    assert.ok(row(s).deleted_at); assert.equal(metric("steps", day), undefined);
    assert.equal(one("SELECT COUNT(*) n FROM hk_values WHERE uuid=?", s.uuid).n, 0);
  }
});

test("bad objects are rejected individually across all three arrays", async () => {
  const good = sample(), bad = sample({ value: "not a number" });
  const b = batch([good, bad, null, sample({ end: "yesterday" }), sample({ end: at("2026-09-30", "10:00") })], {
    deletions: [{ uuid: "bad-deletion" }], daily_stats: [{ type: type("StepCount"), day: "2026-02-30", tz: "Invalid/Zone", sum: 2, unit: "count" }],
  });
  const r = await post(b);
  assert.equal(r.status, 200, r.text); assert.equal(r.json.counts.inserted, 1);
  assert.equal(r.json.counts.rejected, 6); assert.equal(r.json.rejected.length, 6);
  assert.ok(r.json.rejected.find((r) => r.uuid === bad.uuid)?.reason);
  assert.equal(row(bad), undefined); assert.ok(row(good));
  assert.equal(JSON.parse(one("SELECT rejected_json FROM hk_batches WHERE batch_id=?", b.batch_id).rejected_json).length, 6);
});

test("malformed envelopes return 400 without applying objects; raw body and error remain", async () => {
  const s = sample(), count = one("SELECT COUNT(*) n FROM hk_batches").n;
  for (const b of [batch([s], { schema: 2 }), batch([s], { deletions: {} }), batch([s], { client: {} }), null]) {
    const r = await post(b); assert.equal(r.status, 400, r.text); assert.equal(row(s), undefined);
  }
  assert.equal((await post(undefined, { raw: "not JSON" })).status, 400);
  assert.equal(one("SELECT COUNT(*) n FROM hk_batches").n, count);
  assert.match(one("SELECT error FROM payloads ORDER BY id DESC LIMIT 1").error, /JSON/);
});

test("gzip is decoded and stored; invalid gzip and unsupported encodings fail", async () => {
  const s = sample(), b = batch([s]);
  const r = await post(undefined, { raw: gzipSync(body(b)), headers: { "content-encoding": "gzip" } });
  assert.equal(r.status, 200, r.text); assert.ok(row(s));
  assert.deepEqual(JSON.parse(decodePayload(one("SELECT body_gz FROM payloads WHERE id=?", payloadId(b.batch_id)).body_gz, one("SELECT codec FROM payloads WHERE id=?", payloadId(b.batch_id)).codec)), b);
  assert.equal((await post(undefined, { raw: "invalid", headers: { "content-encoding": "gzip" } })).status, 400);
  assert.equal((await post(batch(), { headers: { "content-encoding": "br" } })).status, 415);
});

test("wire and decompressed size limits apply, including no Content-Length", () => {
  const script = `
    process.env.VITALIS_MAX_INGEST_MB = '1'; process.env.VITALIS_DB = ':memory:';
    const { app } = await import('./dist/src/server.js');
    const { createToken } = await import('./dist/src/tokens.js');
    const { gzipSync } = await import('node:zlib');
    const { one } = await import('./dist/src/db.js');
    const headers = { authorization: 'Bearer ' + createToken('limit', 'write').token };
    const a = await app.request('/v2/samples', { method: 'POST', headers: { ...headers, 'content-encoding': 'gzip' }, body: gzipSync(Buffer.alloc((1 << 20) + 1, ' ')) });
    const b = await app.request('/v2/samples', { method: 'POST', headers, body: Buffer.alloc((1 << 20) + 1) });
    const c = await app.request('/v2/samples', { method: 'POST', headers: { ...headers, 'content-length': '1048577' }, body: '{}' });
    console.log(JSON.stringify([a.status,b.status,c.status,one('SELECT COUNT(*) n FROM payloads').n]));
  `;
  const r = spawnSync(process.execPath, ["--input-type=module", "-e", script], { encoding: "utf8" });
  assert.equal(r.status, 0, r.stderr); assert.deepEqual(JSON.parse(r.stdout.trim()), [413, 413, 413, 0]);
});

test("quantity series are stored and replaced; discrete aggregates count points once", async () => {
  const s = sample({ type: type("HeartRate"), value: 100, unit: "count/min", start: at("2026-10-04", "10:00"), end: at("2026-10-04", "10:10"),
    series: [[at("2026-10-04", "10:01"), at("2026-10-04", "10:01"), 80], [at("2026-10-04", "10:02"), at("2026-10-04", "10:02"), 120]] });
  await post(batch([s])); assert.equal(points(s).length, 2);
  let m = metric("heart_rate", "2026-10-04"); assert.deepEqual([m.min, m.avg, m.max], [80, 100, 120]);
  await post(batch([{ ...s, series: [[at("2026-10-04", "10:03"), at("2026-10-04", "10:03"), 95]] }]));
  assert.equal(points(s).length, 1);
  m = metric("heart_rate", "2026-10-04"); assert.deepEqual([m.min, m.avg, m.max], [95, 95, 95]);
  await post(batch([{ ...s, series: undefined }]));
  assert.equal(points(s).length, 0);
  assert.equal(metric("heart_rate", "2026-10-04").avg, 100);
});

test("route and heartbeat children replace wholesale; other kinds retain their fields", async () => {
  const point = [at("2026-10-05", "10:00"), 12.3, 45.6, 100, 2, 3, 4, 90];
  const s = sample({ kind: "route", type: "HKWorkoutRoute", workout_uuid: "workout-id", points: [point, [...point]] });
  await post(batch([s])); assert.equal(points(s).length, 2);
  await post(batch([{ ...s, points: [[point[0], 13, ...point.slice(2)]] }]));
  assert.equal(points(s).length, 1);
  assert.equal(points(s)[0][1], 13);
  const h = sample({ kind: "heartbeat", type: "HKHeartbeatSeriesSample", beats: [[0, false], [0.8, true]] });
  await post(batch([h]));
  assert.deepEqual(points(h).map(([seconds, gap]) => [seconds, gap ? 1 : 0]), [[0, 0], [0.8, 1]]);
  await post(batch([{ ...h, beats: [[0.9, false]] }])); assert.equal(points(h).length, 1);
  for (const specific of [
    { kind: "ecg", classification: 1, symptoms_status: 2, avg_hr: null, sampling_hz: 512, voltages_uv: [1.23456789, -5] },
    { kind: "correlation", objects: [s.uuid, h.uuid] },
    { kind: "state_of_mind", state_kind: 1, valence: -0.5, labels: [1, 2], associations: [4] },
    { kind: "other", payload: { nested: [1, null, true] } },
  ]) {
    const other = sample({ ...specific, type: `Unknown-${specific.kind}` }), r = await post(batch([other]));
    assert.equal(r.json.counts.inserted, 1, r.text);
    for (const [key, value] of Object.entries(specific)) assert.deepEqual(key === "voltages_uv" ? points(other) : JSON.parse(row(other).extra_json)[key], value);
  }
});

test("sleep stages across midnight derive the wake-day hours and edges; deletion and moving a UUID repair nights", async () => {
  const bed = sleep(0, "2026-10-05", "22:00", "23:00", { end: at("2026-10-06", "07:00") });
  const core = sleep(3, "2026-10-05", "23:00", "23:00", { end: at("2026-10-06", "02:00") });
  const deep = sleep(4, "2026-10-06", "02:00", "03:00"), rem = sleep(5, "2026-10-06", "03:00", "04:00");
  const awake = sleep(2, "2026-10-06", "04:00", "04:30"), unspecified = sleep(1, "2026-10-06", "04:30", "06:30");
  const r = await post(batch([bed, core, deep, rem, awake, unspecified])); assert.equal(r.status, 200, r.text);
  let n = one("SELECT * FROM sleep_nights WHERE day='2026-10-06' AND source='Native Watch'");
  assert.deepEqual([n.asleep_h, n.core_h, n.deep_h, n.rem_h, n.awake_h], [7, 3, 1, 1, 0.5]);
  assert.deepEqual([n.sleep_start, n.sleep_end, n.in_bed_start, n.in_bed_end], [core.start, unspecified.end, bed.start, bed.end]);
  assert.equal(one("SELECT * FROM sleep_nights WHERE day='2026-10-05'"), undefined);
  await post(batch([], { deletions: [{ uuid: deep.uuid, type: deep.type }] }));
  n = one("SELECT * FROM sleep_nights WHERE day='2026-10-06' AND source='Native Watch'"); assert.deepEqual([n.asleep_h, n.deep_h], [6, 0]);
  await post(batch([sleep(3, "2026-10-10", "01:00", "02:00", { uuid: core.uuid })]));
  assert.equal(one("SELECT asleep_h FROM sleep_nights WHERE day='2026-10-06' AND source='Native Watch'").asleep_h, 3);
  assert.equal(one("SELECT asleep_h FROM sleep_nights WHERE day='2026-10-10' AND source='Native Watch'").asleep_h, 1);
});

test("deleting all sleep removes the derived night; overlapping unspecified and staged sleep does not double count", async () => {
  const s = sleep(3, "2026-10-11", "01:00", "02:00"), generic = { ...s, uuid: randomUUID(), value: 1, value_label: "asleepUnspecified" };
  await post(batch([s, generic])); assert.equal(one("SELECT asleep_h FROM sleep_nights WHERE day='2026-10-11'").asleep_h, 1);
  await post(batch([], { deletions: [s, generic].map(({ uuid, type }) => ({ uuid, type })) }));
  assert.equal(one("SELECT * FROM sleep_nights WHERE day='2026-10-11'"), undefined);
});

test("daily_stats produce merged totals and fixed discrete units independently of raw source rows", async () => {
  const s = sample({ start: at("2026-10-12", "10:00"), end: at("2026-10-12", "11:00"), value: 200 });
  const b = batch([s], { daily_stats: [
    { type: s.type, day: "2026-10-12", tz: "Asia/Kolkata", sum: 9120, min: null, avg: null, max: null, unit: "count" },
    { type: type("OxygenSaturation"), day: "2026-10-12", tz: "Asia/Kolkata", min: 0.95, avg: 0.97, max: 0.99, unit: "%" },
    { type: "UnknownQuantity", day: "2026-10-12", tz: "Asia/Kolkata", sum: 10, unit: "widgets", future: 2 },
  ] });
  const r = await post(b); assert.equal(r.json.counts.daily_stats, 3, r.text);
  assert.equal(metric("steps", "2026-10-12", "").qty, 9120); assert.equal(metric("steps", "2026-10-12").qty, 200);
  const oxygen = metric("spo2", "2026-10-12", ""); assert.deepEqual([oxygen.min, oxygen.avg, oxygen.max, oxygen.unit], [95, 97, 99, "%"]);
  assert.equal(JSON.parse(one("SELECT content_json FROM hk_daily_stats WHERE type='UnknownQuantity'").content_json).future, 2);
  await post(batch([], { deletions: [{ uuid: s.uuid, type: s.type }] }));
  assert.equal(metric("steps", "2026-10-12"), undefined); assert.equal(metric("steps", "2026-10-12", "").qty, 9120);
});

test("cumulative totals split local midnight and replacement cleans up the previous source/day", async () => {
  const s = sample({ start: "2026-10-13T23:00:00.000+05:30", end: "2026-10-14T01:00:00.000+05:30", value: 200 });
  await post(batch([s])); assert.equal(metric("steps", "2026-10-13").qty, 100); assert.equal(metric("steps", "2026-10-14").qty, 100);
  await post(batch([{ ...s, start: at("2026-10-15", "10:00"), end: at("2026-10-15", "11:00"), source: { name: "Other phone", bundle_id: "phone" } }]));
  assert.equal(metric("steps", "2026-10-13"), undefined); assert.equal(metric("steps", "2026-10-14"), undefined);
  assert.equal(metric("steps", "2026-10-15", "Other phone").qty, 200);
});

test("historical sample tz overrides upload offset; DST midnight splits use elapsed duration", async () => {
  await post(batch([sample({ start: "2026-10-16T03:00:00.000Z", end: "2026-10-16T03:10:00.000Z", tz: "America/New_York" })]));
  assert.equal(metric("steps", "2026-10-15").qty, 100);
  await post(batch([sample({ start: "2026-11-01T00:00:00.000-04:00", end: "2026-11-02T01:00:00.000-05:00", tz: "America/New_York", value: 2600 })]));
  assert.equal(metric("steps", "2026-11-01").qty, 2500); assert.equal(metric("steps", "2026-11-02").qty, 100);
});

test("unknown types and unsupported units remain raw without mislabelled derived metrics", async () => {
  const a = sample({ type: "FutureQuantity", value: 1.23456789, unit: "new-unit" }), b = sample({ type: type("BodyMass"), unit: "widgets" });
  assert.equal((await post(batch([a, b]))).json.counts.inserted, 2); assert.equal(row(a).value, 1.23456789);
  assert.equal(one("SELECT * FROM hk_values WHERE uuid IN (?,?)", a.uuid, b.uuid), undefined);
});

test("workouts use same-source HR; later HR updates, series points and deletions refresh workouts", async () => {
  const w = workout({ start: at("2026-10-17", "10:00"), end: at("2026-10-17", "10:10"), statistics: {
    [type("ActiveEnergyBurned")]: { sum: 418.4, unit: "kJ" }, [type("DistanceWalkingRunning")]: { sum: 1500, unit: "m" },
  } });
  const hr = (hm, value, props = {}) => sample({ type: type("HeartRate"), unit: "count/min", value, start: at("2026-10-17", hm), end: at("2026-10-17", hm), ...props });
  const a = hr("10:01", 80), b = hr("10:02", 120);
  const r = await post(batch([w, a, b, hr("09:59", 20), hr("10:11", 220), hr("10:03", 240, { source: { name: "Other Watch", bundle_id: "other" } })]));
  assert.equal(r.status, 200, r.text);
  const get = () => one("SELECT * FROM hk_workouts WHERE id=?", w.uuid);
  assert.deepEqual([get().hr_min, get().hr_avg, get().hr_max], [80, 100, 120]);
  assert.equal(get().source, "Native Watch"); assert.ok(Math.abs(get().active_kcal - 100) < 1e-10); assert.equal(get().distance_km, 1.5);
  await post(batch([{ ...b, value: 140 }])); assert.equal(get().hr_avg, 110);
  await post(batch([], { deletions: [{ uuid: a.uuid, type: a.type }] })); assert.deepEqual([get().hr_min, get().hr_avg, get().hr_max], [140, 140, 140]);
  await post(batch([hr("10:00", 100, { end: at("2026-10-17", "10:10"), series: [
    [at("2026-10-17", "10:04"), at("2026-10-17", "10:04"), 90], [at("2026-10-17", "10:05"), at("2026-10-17", "10:05"), 130],
  ] })])); assert.equal(get().hr_avg, 120);
  await post(batch([], { deletions: [{ uuid: w.uuid, type: w.type }] })); assert.equal(get(), undefined);
  await post(batch([w])); assert.equal(get(), undefined);
});

test("reparse repairs v2 projections and never undoes newer samples, daily stats or batch idempotency", async () => {
  const s = sample({ start: at("2026-10-18", "10:00"), end: at("2026-10-18", "11:00") });
  const b = batch([s], { daily_stats: [{ type: s.type, day: "2026-10-18", tz: "Asia/Kolkata", sum: 500, unit: "count" }] });
  await post(b); const id = payloadId(b.batch_id);
  run("DELETE FROM metric_days WHERE day='2026-10-18'"); run("UPDATE hk_samples SET native_value=NULL WHERE uuid=?", s.uuid);
  assert.equal(reparse(id).duplicate, false);
  assert.equal(metric("steps", "2026-10-18").qty, 100); assert.equal(metric("steps", "2026-10-18", "").qty, 500);
  await post(batch([{ ...s, value: 150 }], { daily_stats: [{ ...b.daily_stats[0], sum: 800 }] })); reparse(id);
  assert.equal(row(s).value, 150); assert.equal(metric("steps", "2026-10-18").qty, 150); assert.equal(metric("steps", "2026-10-18", "").qty, 800);
  await post({ ...b, upserts: [{ ...s, value: 9000 }] });
  const dupId = one("SELECT id FROM payloads ORDER BY id DESC LIMIT 1").id;
  assert.throws(() => reparse(dupId), /different payload/); assert.equal(row(s).value, 150);
});

test("a batch transaction failure rolls back all objects and records its error for retry", async () => {
  const s = sample(), b = batch([s]);
  const countersBefore = all("SELECT * FROM hk_type_status ORDER BY type");
  db.exec("CREATE TRIGGER v2_fail BEFORE INSERT ON hk_batches BEGIN SELECT RAISE(ABORT, 'simulated batch failure'); END");
  try {
    assert.equal((await post(b)).status, 500); assert.equal(row(s), undefined);
    assert.deepEqual(all("SELECT * FROM hk_type_status ORDER BY type"), countersBefore);
    assert.equal(one("SELECT * FROM hk_batches WHERE batch_id=?", b.batch_id), undefined);
    assert.match(one("SELECT error FROM payloads ORDER BY id DESC LIMIT 1").error, /simulated batch failure/);
  } finally { db.exec("DROP TRIGGER v2_fail"); }
  assert.equal((await post(b)).json.counts.inserted, 1);
});

test("reparse recovers an object rejected by an older parser in an already accepted batch", () => {
  const s = sample({ start: at("2026-08-03", "10:00"), end: at("2026-08-03", "11:00") }), b = batch([s]), raw = body(b);
  const counts = { inserted: 0, updated: 0, unchanged: 0, deleted: 0, daily_stats: 0, rejected: 1 };
  const rejected = [{ uuid: s.uuid, reason: "previous parser did not support this object" }], time = Date.now();
  const id = Number(run("INSERT INTO payloads(received_at,origin,sha256,bytes,body_gz,counts) VALUES(?,'v2',?,?,?,?)",
    time, createHash("sha256").update(raw).digest("hex"), raw.length, gzipSync(raw), JSON.stringify(counts)).lastInsertRowid);
  run("INSERT INTO hk_batches(batch_id,payload_id,received_at,counts_json,rejected_json) VALUES(?,?,?,?,?)",
    b.batch_id, id, time, JSON.stringify(counts), JSON.stringify(rejected));
  const result = reparse(id);
  assert.equal(result.counts.inserted, 1); assert.equal(result.counts.rejected, 0);
  assert.equal(metric("steps", "2026-08-03").qty, 100);
  assert.deepEqual(JSON.parse(one("SELECT rejected_json FROM hk_batches WHERE batch_id=?", b.batch_id).rejected_json), []);
});

test("status accepts any token, counts unknown tombstones, returns newest live end and the last 20 batches", async () => {
  assert.equal((await http("GET", "/v2/sync/status")).status, 401);
  const t = "StatusOnlyQuantity", live = sample({ type: t }), dead = sample({ type: t, end: at("2026-10-20", "10:00") });
  await post(batch([live, dead], { deletions: [{ uuid: dead.uuid, type: t }, { uuid: "never-upserted", type: t }] }));
  for (const token of [ingestToken, readToken, writeToken]) {
    const r = await http("GET", "/v2/sync/status", { token }); assert.equal(r.status, 200);
    assert.deepEqual(r.json.types.find((s) => s.type === t), { type: t, live: 1, deleted: 2, newest_end: live.end });
    assert.equal(r.json.batches.length, 20); assert.equal(r.json.last_batch_at, r.json.batches[0].received_at);
    assert.ok(r.json.batches[0].counts); assert.ok(Array.isArray(r.json.batches[0].rejected));
  }
});

test("auth matches ingest; freshness counts successful v2 batches and excludes invalid or duplicate attempts", async () => {
  const b = batch();
  for (const token of [undefined, "vtl_wrong", readToken]) assert.equal((await post(b, { token })).status, 401);
  assert.equal((await post(b, { token: writeToken })).status, 200);
  const before = freshness(), valid = batch([sample()]);
  assert.equal((await post(valid, { token: undefined, headers: { "x-api-key": ingestToken } })).status, 200);
  const after = freshness(); assert.equal(after.syncs_last_7_days, before.syncs_last_7_days + 1);
  assert.ok(after.last_sync.at); assert.equal(after.last_sync.counts.inserted, 1);
  const short = freshFor(["steps"]); await post(valid); await post(batch([], { schema: 99 }));
  assert.deepEqual(freshFor(["steps"]), short); assert.equal(freshness().syncs_last_7_days, after.syncs_last_7_days);
  assert.ok(freshness().problems_last_7_days.some((p) => p.includes("Invalid sync envelope")));
});

test("stand-hour categories count stood hours; fixed catalog units cover body fat and time", async () => {
  const s = sample({ kind: "category", type: "HKCategoryTypeIdentifierAppleStandHour", value: 0, value_label: "stood",
    start: at("2026-10-21", "10:00"), end: at("2026-10-21", "11:00") });
  await post(batch([s, { ...s, uuid: randomUUID(), value: 1, value_label: "idle", start: at("2026-10-21", "11:00"), end: at("2026-10-21", "12:00") },
    sample({ type: type("BodyFatPercentage"), unit: "%", value: 0.2 }), sample({ type: type("AppleExerciseTime"), unit: "s", value: 120 }),
  ]));
  assert.equal(metric("stand_hours", "2026-10-21").qty, 1);
  assert.equal(metric("body_fat_pct", "2026-10-01").avg, 20);
  assert.equal(metric("exercise_min", "2026-10-01").qty, 2);
});

test("sleep source replacement and reparse preserve disconnected naps on the same wake day", async () => {
  const night = sleep(3, "2026-10-22", "01:00", "07:00"), nap = sleep(4, "2026-10-22", "15:00", "16:00");
  const b = batch([night, nap]); await post(b);
  assert.equal(one("SELECT asleep_h FROM sleep_nights WHERE day='2026-10-22' AND source='Native Watch'").asleep_h, 7);
  await post(batch([{ ...night, source: { name: "New Sleep Watch", bundle_id: "new.sleep" } }]));
  assert.equal(one("SELECT asleep_h FROM sleep_nights WHERE day='2026-10-22' AND source='Native Watch'").asleep_h, 1);
  assert.equal(one("SELECT asleep_h FROM sleep_nights WHERE day='2026-10-22' AND source='New Sleep Watch'").asleep_h, 6);
  reparse(payloadId(b.batch_id));
  assert.equal(one("SELECT asleep_h FROM sleep_nights WHERE day='2026-10-22' AND source='Native Watch'").asleep_h, 1);
});

test("native deletion leaves unrelated Health Auto Export data intact", async () => {
  const { ingest, payload } = await import("./_env.mjs");
  ingest(body(payload("2026-08-01", 1)), { origin: "test-hae" });
  const before = all("SELECT * FROM metric_days WHERE day='2026-08-01'");
  await post(batch([], { deletions: [{ uuid: "hae-unrelated", type: type("StepCount") }] }));
  assert.deepEqual(all("SELECT * FROM metric_days WHERE day='2026-08-01'"), before);
});

test("reparse --all continues after a malformed v2 envelope and rebuilds a later payload", () => {
  const script = `
    import { mkdtempSync } from 'node:fs'; import { join } from 'node:path'; import { tmpdir } from 'node:os';
    import { spawnSync } from 'node:child_process';
    process.env.VITALIS_ROOT=mkdtempSync(join(tmpdir(),'vitalis-v2-reparse-'));
    delete process.env.VITALIS_DB;
    const { ingestV2 } = await import('./dist/src/v2.js');
    const { one,run } = await import('./dist/src/db.js');
    try { ingestV2(Buffer.from('{"schema":2}')); } catch {}
    ingestV2(Buffer.from(JSON.stringify(${JSON.stringify(batch([sample({ uuid: "cli-replay", start: at("2026-08-02", "10:00"), end: at("2026-08-02", "11:00") })]))})));
    run("DELETE FROM metric_days WHERE day='2026-08-02'");
    const cli=spawnSync(process.execPath,['dist/src/cli.js','reparse','--all'],{encoding:'utf8'});
    console.log(JSON.stringify({status:cli.status,stdout:cli.stdout,stderr:cli.stderr,qty:one("SELECT qty FROM metric_days WHERE day='2026-08-02'").qty}));
  `;
  const r = spawnSync(process.execPath, ["--input-type=module", "-e", script], { encoding: "utf8" });
  assert.equal(r.status, 0, r.stderr);
  const result = JSON.parse(r.stdout.trim()); assert.equal(result.status, 1);
  assert.match(result.stderr, /Invalid sync envelope/); assert.match(result.stdout, /payload 2:/); assert.equal(result.qty, 100);
});

test("additive schema starts against an existing production-format database and preserves legacy rows", () => {
  const script = `
    import { mkdtempSync } from 'node:fs'; import { join } from 'node:path'; import { tmpdir } from 'node:os';
    import { DatabaseSync } from 'node:sqlite';
    process.env.VITALIS_ROOT=mkdtempSync(join(tmpdir(),'vitalis-v2-legacy-')); delete process.env.VITALIS_DB;
    const old=new DatabaseSync(join(process.env.VITALIS_ROOT,'vitalis.db'));
    old.exec(\`CREATE TABLE payloads (id INTEGER PRIMARY KEY AUTOINCREMENT, received_at INTEGER NOT NULL, origin TEXT NOT NULL,
      sha256 TEXT NOT NULL UNIQUE,bytes INTEGER NOT NULL,body_gz BLOB NOT NULL,automation TEXT,aggregation TEXT,period TEXT,parsed_at INTEGER,counts TEXT,warnings TEXT,error TEXT);
      CREATE TABLE metric_days (metric TEXT NOT NULL,day TEXT NOT NULL,source TEXT NOT NULL,qty REAL,min REAL,avg REAL,max REAL,unit TEXT NOT NULL,
      payload_id INTEGER,updated_at INTEGER NOT NULL,PRIMARY KEY(metric,day,source));
      INSERT INTO metric_days VALUES('steps','2020-01-01','',123,NULL,NULL,NULL,'steps',NULL,1);\`);
    old.close();
    const { app }=await import('./dist/src/server.js');
    const { createToken }=await import('./dist/src/tokens.js');
    const { one }=await import('./dist/src/db.js');
    const status=await (await app.request('/v2/sync/status',{headers:{authorization:'Bearer '+createToken('legacy','read').token}})).json();
    console.log(JSON.stringify({health:(await app.request('/health')).status,qty:one("SELECT qty FROM metric_days").qty,status,
      tables:one("SELECT COUNT(*) n FROM sqlite_master WHERE type='table' AND name LIKE 'hk_%'").n}));
  `;
  const r = spawnSync(process.execPath, ["--input-type=module", "-e", script], { encoding: "utf8" });
  assert.equal(r.status, 0, r.stderr); const result = JSON.parse(r.stdout.trim());
  assert.equal(result.health, 200); assert.equal(result.qty, 123); assert.equal(result.tables, 13);
  assert.deepEqual(result.status, { last_batch_at: null, types: [], batches: [] });
});

test("a UUID changing kind replaces bulky children and removes its old derived workout", async () => {
  const w = workout({ start: at("2026-08-04", "10:00"), end: at("2026-08-04", "11:00") });
  await post(batch([w])); assert.ok(one("SELECT * FROM hk_workouts WHERE id=?", w.uuid));
  await post(batch([sample({ uuid: w.uuid, start: w.start, end: w.end, series: [[w.start, w.end, 100]] })]));
  assert.equal(one("SELECT * FROM hk_workouts WHERE id=?", w.uuid), undefined);
  assert.equal(points(w).length, 1);
  await post(batch([w]));
  assert.equal(points(w).length, 0);
  assert.equal(metric("steps", "2026-08-04"), undefined);
});

test("workout statistics win; cycling distance converts; fallback HR refreshes across sources", async () => {
  const source = { name: "Workout Recorder", bundle_id: "workout.recorder" };
  const w = workout({ source, start: at("2027-01-01", "10:00"), end: at("2027-01-01", "11:00"), statistics: {
    [type("HeartRate")]: { min: 1, avg: 2, max: 3, unit: "count/s" },
    [type("DistanceCycling")]: { sum: 12500, unit: "m" },
  } });
  const hr = sample({ type: type("HeartRate"), unit: "count/min", value: 100,
    start: at("2027-01-01", "10:30"), end: at("2027-01-01", "10:30") });
  const get = () => one("SELECT * FROM hk_workouts WHERE id=?", w.uuid);
  await post(batch([w, hr]));
  assert.deepEqual([get().hr_min, get().hr_avg, get().hr_max, get().distance_km], [60, 120, 180, 12.5]);
  await post(batch([{ ...hr, value: 200 }])); assert.equal(get().hr_avg, 120);
  await post(batch([{ ...w, statistics: {} }])); assert.equal(get().hr_avg, 200);
  const preferred = { ...hr, uuid: randomUUID(), source, value: 130 };
  await post(batch([preferred])); assert.equal(get().hr_avg, 130);
  await post(batch([], { deletions: [{ uuid: preferred.uuid, type: preferred.type }] })); assert.equal(get().hr_avg, 200);
  await post(batch([], { deletions: [{ uuid: hr.uuid, type: hr.type }] })); assert.equal(get().hr_avg, null);
  await post(batch([{ ...hr, uuid: randomUUID(), value: 110 }])); assert.equal(get().hr_avg, 110);
});

test("unstaged sleep and unobserved awake remain null, while observed staged absences are zero", async () => {
  const generic = sleep(1, "2027-01-02", "01:00", "07:00");
  await post(batch([generic]));
  const get = () => one("SELECT * FROM sleep_nights WHERE day='2027-01-02' AND source='Native Watch'");
  assert.deepEqual([get().core_h, get().deep_h, get().rem_h, get().awake_h], [null, null, null, null]);
  const core = { ...generic, uuid: randomUUID(), value: 3, value_label: "asleepCore" };
  await post(batch([core])); assert.deepEqual([get().core_h, get().deep_h, get().rem_h, get().awake_h], [6, 0, 0, null]);
  await post(batch([], { deletions: [{ uuid: core.uuid, type: core.type }] }));
  assert.deepEqual([get().core_h, get().deep_h, get().rem_h, get().awake_h], [null, null, null, null]);
});

test("a reused batch id with different bytes returns 409 and applies no objects", async () => {
  const s = sample({ start: at("2027-01-03", "10:00"), end: at("2027-01-03", "10:10") });
  const b = batch([s]); assert.equal((await post(b)).status, 200);
  const original = one("SELECT * FROM hk_batches WHERE batch_id=?", b.batch_id);
  const r = await post({ ...b, upserts: [{ ...s, value: 999 }] });
  assert.equal(r.status, 409); assert.match(r.json.error, /different payload/);
  assert.equal(row(s).value, 100); assert.deepEqual(one("SELECT * FROM hk_batches WHERE batch_id=?", b.batch_id), original);
  assert.equal((await post(b)).json.duplicate, true);
});

test("sleep wake day follows asleep end even when in-bed/awake extends across the next midnight", async () => {
  const bed = sleep(0, "2027-01-04", "17:00", "18:00", { end: at("2027-01-05", "00:30") });
  const asleep = sleep(1, "2027-01-04", "18:00", "23:00");
  const awake = sleep(2, "2027-01-04", "23:00", "23:30", { end: at("2027-01-05", "00:30") });
  await post(batch([bed, asleep, awake]));
  const n = one("SELECT * FROM sleep_nights WHERE day='2027-01-04' AND source='Native Watch'");
  assert.equal(n.sleep_end, asleep.end); assert.equal(n.in_bed_end, bed.end); assert.equal(n.asleep_h, 5);
  assert.equal(one("SELECT * FROM sleep_nights WHERE day='2027-01-05' AND source='Native Watch'"), undefined);
});

test("status counters track type replacement, newest deletion, unknown tombstones and late upserts once", async () => {
  const t = "CounterRegression", moved = "CounterMoved";
  const a = sample({ type: t, start: at("2027-01-06", "10:00"), end: at("2027-01-06", "11:00") });
  const b = { ...a, uuid: randomUUID(), end: at("2027-01-06", "12:00") }, unknown = randomUUID();
  const get = async () => (await http("GET", "/v2/sync/status", { token: readToken })).json.types.find(x => x.type === t);
  await post(batch([a, b])); assert.deepEqual(await get(), { type: t, live: 2, deleted: 0, newest_end: b.end });
  await post(batch([], { deletions: [{ uuid: b.uuid, type: t }, { uuid: unknown, type: t }] }));
  assert.deepEqual(await get(), { type: t, live: 1, deleted: 2, newest_end: a.end });
  await post(batch([{ ...a, uuid: unknown }])); await post(batch([{ ...a, uuid: unknown, value: 999 }]));
  assert.deepEqual(await get(), { type: t, live: 1, deleted: 2, newest_end: a.end });
  await post(batch([{ ...a, type: moved }]));
  assert.deepEqual(await get(), { type: t, live: 0, deleted: 2, newest_end: null });
});

test("sleep range is bounded on both sides and preserves long enclosing segments", async () => {
  const plan = all(`EXPLAIN QUERY PLAN SELECT * FROM hk_samples WHERE kind=1 AND deleted_at IS NULL
    AND source_id IN (SELECT id FROM hk_sources WHERE name=?) AND start_ms BETWEEN ? AND ? AND end_ms>=?`, "Bounded Watch", 0, 1, 0);
  assert.ok(plan.some(r => /SEARCH.*hk_samples_sleep.*start_ms>\? AND start_ms<\?/.test(r.detail)), JSON.stringify(plan));
  const bed = sleep(0, "2027-01-07", "18:00", "19:00", { source: { name: "Bounded Watch", bundle_id: "bounded" }, end: at("2027-01-09", "08:00") });
  const core = sleep(3, "2027-01-09", "01:00", "07:00", { source: bed.source });
  await post(batch([bed])); await post(batch([core]));
  const n = one("SELECT * FROM sleep_nights WHERE day='2027-01-09' AND source='Bounded Watch'");
  assert.equal(n.in_bed_start, bed.start); assert.equal(n.sleep_end, core.end);
});

test("tombstones clear every child and ECG content, including deletion-before-upsert and re-upsert", async () => {
  for (const before of [false, true]) for (const specific of [
    { kind: "quantity", series: [[at("2027-01-10", "10:00"), at("2027-01-10", "10:01"), 3]] },
    { kind: "route", type: "HKWorkoutRoute", workout_uuid: "parent", points: [[at("2027-01-10", "10:00"), 12, 13, 0, 1, 1, 1, 90]] },
    { kind: "heartbeat", type: "HKHeartbeatSeriesSample", beats: [[0, false], [1, true]] },
    { kind: "ecg", type: "HKElectrocardiogramType", classification: 1, symptoms_status: 0, avg_hr: 70, sampling_hz: 512, voltages_uv: [12, 34] },
  ]) {
    const s = sample({ ...specific, metadata: { sensitive: "content" } }), d = { uuid: s.uuid, type: s.type };
    if (!before) await post(batch([s]));
    await post(batch([], { deletions: [d] })); await post(batch([s]));
    const r = row(s); assert.ok(r.deleted_at); assert.equal(r.value, null); assert.equal(r.metadata_json, null);
    assert.deepEqual(JSON.parse(r.extra_json), {});
    assert.equal(blobFor(s.uuid), undefined);
    assert.equal(one("SELECT COUNT(*) n FROM hk_value_days WHERE sample_id=(SELECT id FROM hk_samples WHERE uuid=?)", s.uuid).n, 0);
    assert.equal(one("SELECT COUNT(*) n FROM hk_values WHERE uuid=?", s.uuid).n, 0);
  }
});

test("packed blobs preserve Float64 precision, timestamp offsets, fractional seconds and array order", async () => {
  const start = "2027-03-01T10:00:00.123456+05:30", end = "2027-03-01T10:01:00Z";
  for (const specific of [
    { kind: "quantity", series: [[start, start, 1.234567891234567], [end, end, -0.0000000123456789]] },
    { kind: "route", type: "HKWorkoutRoute", workout_uuid: "parent", points: [[start, 12.123456789123, -13.987654321987, 1.123456789, 0.123456789, 2.34567891234, 3.45678912345, 90.123456789]] },
    { kind: "heartbeat", type: "HKHeartbeatSeriesSample", beats: [[0.123456789123, false], [0.987654321987, true]] },
    { kind: "ecg", type: "HKElectrocardiogramType", classification: 1, symptoms_status: 0, avg_hr: 70, sampling_hz: 512, voltages_uv: [1.23456789123456, -0.000000123456789] },
  ]) {
    const s = sample({ ...specific, start, end }); const r = await post(batch([s])); assert.equal(r.status, 200, r.text);
    assert.deepEqual(points(s), specific.series ?? specific.points ?? specific.beats ?? specific.voltages_uv);
    assert.equal(row(s).start_iso, start); assert.equal(row(s).end_iso, end);
    assert.equal(Buffer.from(blobFor(s.uuid))[0], 1);
  }
});

test("compact scalar rows share dictionaries and avoid a duplicate per-sample projection", async () => {
  const source = { name: "Dictionary Watch", bundle_id: "dictionary", version: "1" }, device = { model: "Dictionary Device", name: "Watch" };
  const a = sample({ source, device, start: at("2027-03-02", "10:00"), end: at("2027-03-02", "10:01") });
  const b = { ...a, uuid: randomUUID(), source: Object.fromEntries(Object.entries(source).reverse()), device: Object.fromEntries(Object.entries(device).reverse()) };
  await post(batch([a, b]));
  assert.equal(one("SELECT COUNT(*) n FROM hk_sources WHERE name='Dictionary Watch'").n, 1);
  const rows = all("SELECT source_id,device_id,json FROM hk_samples WHERE uuid IN (?,?)", a.uuid, b.uuid);
  assert.equal(rows[0].source_id, rows[1].source_id); assert.equal(rows[0].device_id, rows[1].device_id);
  assert.equal(rows[0].json, null);
  assert.equal(one("SELECT COUNT(*) n FROM hk_value_days WHERE sample_id IN (SELECT id FROM hk_samples WHERE uuid IN (?,?))", a.uuid, b.uuid).n, 0);
  assert.equal(metric("steps", "2027-03-02", source.name).qty, 200);
});

test("compressed series summaries retain point-weighted means across samples and days", async () => {
  const a = sample({ type: type("HeartRate"), value: 500, unit: "count/min", start: at("2027-03-03", "10:00"), end: at("2027-03-03", "10:10"),
    series: [[at("2027-03-03", "10:00"), at("2027-03-03", "10:00"), 60], [at("2027-03-03", "10:01"), at("2027-03-03", "10:01"), 90]] });
  const b = { ...a, uuid: randomUUID(), series: [[at("2027-03-03", "10:02"), at("2027-03-03", "10:02"), 150]] };
  await post(batch([a, b]));
  const m = metric("heart_rate", "2027-03-03"); assert.deepEqual([m.min, m.avg, m.max], [60, 100, 150]);
  assert.equal(one("SELECT COUNT(*) n FROM hk_value_days WHERE sample_id=(SELECT id FROM hk_samples WHERE uuid=?)", a.uuid).n, 1);
});

test("malformed primitive daily stats remain per-object rejections in a batch lookup", async () => {
  const r = await post(batch([sample()], { daily_stats: ["bad", 1, null, true, []] }));
  assert.equal(r.status, 200, r.text); assert.equal(r.json.counts.inserted, 1); assert.equal(r.json.counts.rejected, 5);
});

test("health answers while a 5000-object native batch is still running in the worker", async () => {
  const samples = Array.from({ length: 5000 }, (_, i) => sample({ start: at("2027-03-04", "10:00"), end: at("2027-03-04", "10:01"), value: i % 100 }));
  let finished = false;
  const pending = post(batch(samples)).then(r => { finished = true; return r; });
  await new Promise(resolve => setTimeout(resolve, 1));
  const health = await http("GET", "/health");
  assert.equal(health.status, 200); assert.equal(finished, false, "ingest must not monopolize the read thread");
  const result = await pending; assert.equal(result.status, 200, result.text); assert.equal(result.json.counts.inserted, 5000);
});

test("MCP reads and token-use auditing do not wait on another connection's write transaction", async () => {
  const { Worker } = await import('node:worker_threads');
  const { join } = await import('node:path');
  const { flushAudits } = await import('../dist/src/db.js');
  const { call } = await import('./_env.mjs');
  const token = tokens.createToken('unused read token during writer', 'read');
  const before = one("SELECT COUNT(*) n FROM calls WHERE token_id=?", token.id).n;
  const writer = new Worker(`const {parentPort,workerData}=require('node:worker_threads'); const {DatabaseSync}=require('node:sqlite');
    const db=new DatabaseSync(workerData); db.exec('BEGIN IMMEDIATE'); parentPort.postMessage('locked');
    parentPort.once('message',()=>{db.exec('COMMIT');db.close();parentPort.close();});`, { eval: true, workerData: join(process.env.VITALIS_ROOT, 'vitalis.db') });
  await new Promise((resolve, reject) => { writer.once('message', resolve); writer.once('error', reject); });
  const started = performance.now();
  try {
    const status = await http('GET', '/v2/sync/status', { token: token.token }); assert.equal(status.status, 200);
    const read = await call(token.token, 'get_freshness'); assert.equal(read.isError, false);
    assert.ok(performance.now() - started < 1000, 'read waited for SQLite busy_timeout');
  } finally {
    const exited = new Promise(resolve => writer.once('exit', resolve)); writer.postMessage('release'); await exited; flushAudits();
  }
  assert.equal(one("SELECT COUNT(*) n FROM calls WHERE token_id=?", token.id).n, before + 1);
  assert.ok(one("SELECT last_used_at FROM tokens WHERE id=?", token.id).last_used_at);
});

test("HR series windows use point bounds, including points outside the parent interval", async () => {
  const w = workout({ start: at("2027-04-01", "10:00"), end: at("2027-04-01", "11:00") });
  const h = sample({ type: type("HeartRate"), unit: "count/min", value: 500, start: at("2027-04-01", "08:00"), end: at("2027-04-01", "08:10"),
    series: [[at("2027-04-01", "10:30"), at("2027-04-01", "10:30"), 100]] });
  await post(batch([w])); await post(batch([h]));
  const get = () => one("SELECT hr_avg FROM hk_workouts WHERE id=?", w.uuid).hr_avg;
  assert.equal(get(), 100);
  await post(batch([{ ...h, series: [[at("2027-04-01", "12:00"), at("2027-04-01", "12:00"), 130]] }]));
  assert.equal(get(), null);
  const wrongKind = sample({ type: type("HeartRate"), kind: "category", value: 1, value_label: "unmapped", start: at("2027-04-01", "10:30"), end: at("2027-04-01", "10:30") });
  assert.equal((await post(batch([wrongKind]))).status, 200); assert.equal(get(), null);
});

test("native replay decodes mixed gzip/zstd retention while legacy gzip payloads stay compatible", () => {
  const script = `
    process.env.VITALIS_DB=':memory:';
    const {ingestV2}=await import('./dist/src/v2.js');
    const {reparse}=await import('./dist/src/ingest.js');
    const {one,run}=await import('./dist/src/db.js');
    const {decodePayload}=await import('./dist/src/v2-payload.js');
    const z=await import('node:zlib');
    const results=[];
    for (const codec of ['auto','gzip']) {
      if(codec==='gzip')process.env.VITALIS_PAYLOAD_CODEC='gzip';else delete process.env.VITALIS_PAYLOAD_CODEC;
      const b=${JSON.stringify(batch([sample({ start: at("2027-04-02", "10:00"), end: at("2027-04-02", "10:01") })]))};
      b.batch_id=codec;b.upserts[0].uuid=codec;
      const raw=Buffer.from(JSON.stringify(b));ingestV2(raw);
      const p=one('SELECT id,codec,body_gz FROM payloads ORDER BY id DESC LIMIT 1');
      if(!decodePayload(p.body_gz,p.codec).equals(raw))throw Error('retention round trip');
      run("UPDATE hk_samples SET native_value=NULL WHERE uuid=?",codec);reparse(p.id);
      results.push([p.codec,one("SELECT native_value FROM hk_samples WHERE uuid=?",codec).native_value]);
    }
    console.log(JSON.stringify({zstd:typeof z.zstdCompressSync==='function',results}));
  `;
  const r = spawnSync(process.execPath, ['--input-type=module', '-e', script], { encoding: 'utf8' });
  assert.equal(r.status, 0, r.stderr); const result = JSON.parse(r.stdout.trim());
  assert.deepEqual(result.results, [[result.zstd ? 'zstd' : 'gzip', 100], ['gzip', 100]]);
});

test("compact timestamps preserve explicit negative-zero offsets", async () => {
  const s = sample({ start: '2027-04-03T10:00:00.123-00:00', end: '2027-04-03T10:01:00.123-00:00',
    series: [['2027-04-03T10:00:00.123-00:00', '2027-04-03T10:01:00.123-00:00', 12]] });
  assert.equal((await post(batch([s]))).status, 200);
  assert.equal(row(s).start_iso, s.start); assert.equal(row(s).end_iso, s.end); assert.deepEqual(points(s), s.series);
});
