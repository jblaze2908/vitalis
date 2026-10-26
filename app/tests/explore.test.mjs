import { test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { addDays, body, call, http, ingest, payload, tokens } from "./_env.mjs";
import { today } from "../dist/src/time.js";

const ingestToken = tokens.createToken("explore phone", "ingest").token;
const write = tokens.createToken("explore writer", "write").token;
const read = tokens.createToken("explore reader", "read").token;
const D = addDays(today(), -1);
const at = (hm, day = D) => `${day}T${hm}:00.000+05:30`;
const source = { name: "Native Watch", bundle_id: "com.apple.health", version: "1", os_version: "26" };
const batch = (upserts) => ({ schema: 1, batch_id: randomUUID(), client: { install_id: "t", app_version: "0.1", os: "iOS 26", model: "T" }, upserts, deletions: [], daily_stats: [] });
const postSamples = (u) => http("POST", "/v2/samples", { token: ingestToken, json: batch(u) });
const hr = (start, end, series) => ({ uuid: randomUUID(), type: "HKQuantityTypeIdentifierHeartRate", kind: "quantity", start, end, source, value: series[0][2], unit: "count/min", series });
const get = (path) => http("GET", path, { token: read });

test("a cardio workout carries its heart-rate line; /v2/heart buckets the day and marks the workout", async () => {
  const w = { uuid: randomUUID(), type: "HKWorkoutTypeIdentifier", kind: "workout", start: at("07:00"), end: at("07:30"), source, activity_type: 37,
    activity_name: "running", duration_s: 1800, events: [], activities: [], statistics: {} };
  const series = [["07:01", 120], ["07:10", 150], ["07:20", 170], ["07:29", 140], ["13:02", 70], ["13:04", 80]].map(([t, v]) => [at(t), at(t), v]);
  assert.equal((await postSamples([w, hr(at("07:00"), at("13:05"), series)])).status, 200);

  const s = await get(`/v2/training/sessions/${w.uuid}`);
  assert.equal(s.status, 200, s.text);
  assert.equal(s.json.kind, "cardio");
  assert.deepEqual([s.json.hr.min, s.json.hr.avg, s.json.hr.max], [120, 145, 170]);
  assert.equal(s.json.hr.points.length, 4);
  assert.ok(s.json.hr.points.every((p, i, a) => i === 0 || p.s > a[i - 1].s));
  assert.equal(s.json.start_ms, undefined);

  const h = await get(`/v2/heart?date=${D}`);
  assert.equal(h.status, 200, h.text);
  assert.equal(h.json.readings, 6);
  assert.deepEqual(h.json.points.find((p) => p.m === 13 * 60), { m: 780, avg: 75, lo: 70, hi: 80 });
  assert.deepEqual([h.json.summary.min, h.json.summary.min_at, h.json.summary.max, h.json.summary.max_at], [70, "13:02", 170, "07:20"]);
  assert.deepEqual(h.json.workouts.map((x) => [x.title, x.start_m, x.end_m]), [["running", 420, 450]]);
  assert.equal(h.json.next_day, today());
  assert.equal((await get("/v2/heart?date=nope")).status, 400);

  // A phone session linked to this Watch workout takes its place, so the row opens the strength view.
  const linked = await http("POST", "/v2/workouts", { token: write, json: {
    session: { client_id: "L-1", title: "Legs", source: "phone", started_at: at("07:00"), ended_at: at("07:30"), tz_offset_min: 330, hk_workout_uuid: w.uuid },
    sets: [{ id: "L-1-0", exercise: "barbell-squat", kind: "normal", weight_kg: 100, reps: 5, performed_at: at("07:05") }] } });
  assert.equal(linked.status, 200, linked.text);
  const again = await get(`/v2/heart?date=${D}`);
  assert.deepEqual(again.json.workouts.map((x) => [x.id, x.title]), [["L-1", "Legs"]]);
  const strength = await get("/v2/training/sessions/L-1");
  assert.equal(strength.json.kind, "strength"); assert.equal(strength.json.hr.max, 170);

  // Deleting the session takes its Health twin out of every list instead of leaving it behind as a separate workout.
  const del = await call(write, "edit_workout", { id: "L-1", delete: true });
  assert.ok(!del.isError, JSON.stringify(del));
  assert.deepEqual((await get(`/v2/heart?date=${D}`)).json.workouts, []);
  const page = await get("/v2/training/sessions");
  assert.ok(!page.json.sessions.some((x) => x.id === w.uuid || x.id === "L-1"), JSON.stringify(page.json.sessions));
});

test("/v2/training/exercises lists performed exercises newest first with e1RM; exercise detail has per-session history", async () => {
  const day = (n) => addDays(today(), -n);
  const post = (id, d, sets) => http("POST", "/v2/workouts", { token: write, json: {
    session: { client_id: id, title: "Push", source: "phone", started_at: at("18:00", d), ended_at: at("19:00", d), tz_offset_min: 330 },
    sets: sets.map(([ex, kg, reps], i) => ({ id: `${id}-${i}`, exercise: ex, kind: "normal", weight_kg: kg, reps, performed_at: at(`18:${String(10 + i).padStart(2, "0")}`, d) })) } });
  { const r1 = await post("E-1", day(10), [["barbell-bench-press-medium-grip", 80, 5], ["barbell-squat", 100, 5]]); assert.equal(r1.status, 200, r1.text); }
  assert.equal((await post("E-2", day(3), [["barbell-bench-press-medium-grip", 85, 5], ["barbell-bench-press-medium-grip", 80, 8]])).status, 200);

  const r = await get("/v2/training/exercises");
  assert.equal(r.status, 200, r.text);
  // The first test's squat session was deleted, so it counts for nothing here.
  assert.deepEqual(r.json.exercises.map((x) => x.id), ["barbell-bench-press-medium-grip", "barbell-squat"]);
  const [bench, squat] = r.json.exercises;
  assert.equal(bench.sessions, 2); assert.equal(bench.working_sets, 3); assert.equal(bench.heaviest_kg, 85);
  assert.deepEqual(bench.last_top, { weight_kg: 85, reps: 5 });
  assert.equal(bench.last_day, day(3));
  assert.deepEqual(bench.spark, [93.3, 101.3]);
  assert.equal(bench.e1rm_kg, 101.3); assert.equal(bench.change_8w_kg, 8);
  assert.equal(squat.sessions, 1);

  const d = await get(`/v2/exercises/${bench.id}`);
  assert.equal(d.status, 200, d.text);
  assert.deepEqual(d.json.history.map((h) => [h.day, h.sets.length, h.volume_kg]), [[day(3), 2, 1065], [day(10), 1, 400]]);
});

test("/v2/metrics groups every stored metric with latest vs usual; /v2/metrics/:key returns a range with its usual band", async () => {
  const from = addDays(today(), -80);
  assert.equal(ingest(body(payload(from, 80, (i) => ({ rhr: 55 + (i % 5) }))), { origin: "test" }).ok ?? true, true);

  const o = await get("/v2/metrics");
  assert.equal(o.status, 200, o.text);
  assert.deepEqual(o.json.groups.map((g) => g.name).slice(0, 4), ["Heart", "Sleep", "Activity", "Body"]);
  const rhr = o.json.groups[0].metrics.find((m) => m.key === "resting_hr");
  assert.equal(rhr.name, "Resting heart rate"); assert.equal(rhr.unit, "bpm"); assert.equal(rhr.spark.length, 14);
  assert.ok(rhr.value !== null && rhr.usual !== null);
  const vo2 = o.json.groups[0].metrics.find((m) => m.key === "vo2max");
  assert.equal(vo2.value, null);

  const h = await get("/v2/metrics/resting_hr?days=30");
  assert.equal(h.status, 200, h.text);
  assert.equal(h.json.every, "day"); assert.equal(h.json.points.length, h.json.days_with_data);
  assert.ok(h.json.usual.low <= h.json.usual.value && h.json.usual.value <= h.json.usual.high);
  assert.equal(h.json.next_end, null);
  const y = await get("/v2/metrics/steps?days=365");
  assert.equal(y.json.every, "week"); assert.ok(y.json.points.length >= 11 && y.json.points.length <= 13);
  const band = await get("/v2/metrics/heart_rate?days=7");
  assert.deepEqual(band.json.band.at(-1), { day: band.json.band.at(-1).day, lo: 50, hi: 150 });
  assert.equal((await get("/v2/metrics/resting_hr?days=12")).status, 400);
  assert.equal((await get("/v2/metrics/nope")).status, 404);
  assert.equal((await get("/v2/metrics/bedtime")).status, 404);
});
