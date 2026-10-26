import { test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { addDays, call, http, tokens } from "./_env.mjs";
import { today } from "../dist/src/time.js";

const ingestToken = tokens.createToken("visit phone", "ingest").token;
const write = tokens.createToken("visit writer", "write").token;
const read = tokens.createToken("visit reader", "read").token;
const D = addDays(today(), -2);
const at = (hm, day = D) => `${day}T${hm}:00.000+05:30`;
const source = { name: "Test Apple Watch", bundle_id: "com.apple.health", version: "1", os_version: "26" };
const workout = (name, start, end, stats = {}) => ({ uuid: randomUUID(), type: "HKWorkoutTypeIdentifier", kind: "workout", start: at(start), end: at(end), source,
  activity_type: 1, activity_name: name, duration_s: (Date.parse(at(end)) - Date.parse(at(start))) / 1000, events: [], activities: [], statistics: stats });
const hr = (avg, max) => ({ HKQuantityTypeIdentifierHeartRate: { unit: "count/min", min: avg - 20, avg, max } });
const post = (upserts) => http("POST", "/v2/samples", { token: ingestToken, json: { schema: 1, batch_id: randomUUID(),
  client: { install_id: "t", app_version: "0.1", os: "iOS 26", model: "T" }, upserts, deletions: [], daily_stats: [] } });
const get = (path) => http("GET", path, { token: read });

// The 14 Oct shape: three Watch workouts minutes apart at the gym, then a walk home two hours later.
const walk = workout("walking", "19:10", "19:15", hr(150, 160)), ell = workout("elliptical", "19:16", "19:31", hr(166, 175)),
  bike = workout("cycling", "19:34", "19:49", hr(158, 170)), later = workout("walking", "21:50", "22:00", hr(110, 120));

test("back-to-back Watch workouts are one visit; any member's id opens it; a later walk stays apart", async () => {
  assert.equal((await post([walk, ell, bike, later])).status, 200);
  const rows = (await get("/v2/training/sessions")).json.sessions.filter((r) => r.day === D);
  assert.deepEqual(rows.map((r) => [r.id, r.title, r.part_count ?? 1]), [[later.uuid, "walking", 1], [walk.uuid, "walking · elliptical · cycling", 3]]);
  const v = rows[1];
  assert.equal(v.duration_min, 39);
  assert.equal(v.hr_avg, Math.round((150 * 5 + 166 * 15 + 158 * 15) / 35));
  for (const id of [walk.uuid, ell.uuid, bike.uuid]) {
    const d = (await get(`/v2/training/sessions/${id}`)).json;
    assert.equal(d.id, walk.uuid); assert.equal(d.kind, "cardio");
    assert.deepEqual(d.parts.map((p) => p.title), ["walking", "elliptical", "cycling"]);
    assert.equal(d.hr_max, 175); assert.equal(d.duration_s, 39 * 60);
  }
  assert.equal((await get(`/v2/training/sessions/${later.uuid}`)).json.parts, undefined);
});

test("sets logged on the phone during the visit make it a strength visit with the Watch parts inside", async () => {
  const r = await http("POST", "/v2/workouts", { token: write, json: {
    session: { client_id: "V-1", title: "Legs", source: "phone", started_at: at("19:52"), ended_at: at("20:30"), tz_offset_min: 330 },
    sets: [{ id: "V-1-0", exercise: "barbell-squat", kind: "normal", weight_kg: 100, reps: 5, performed_at: at("19:55") }] } });
  assert.equal(r.status, 200, r.text);
  const rows = (await get("/v2/training/sessions")).json.sessions.filter((x) => x.day === D);
  assert.deepEqual(rows.map((x) => [x.id, x.kind, x.title, x.part_count ?? 1]), [[later.uuid, "cardio", "walking", 1], ["V-1", "strength", "Legs", 4]]);
  const d = (await get(`/v2/training/sessions/${ell.uuid}`)).json;
  assert.equal(d.id, "V-1"); assert.equal(d.kind, "strength"); assert.equal(d.title, "Legs");
  assert.equal(d.start, walk.start); assert.equal(d.duration_min, 80);
  assert.equal(d.exercises.length, 1); assert.equal(d.parts.length, 4);
  // Deleting the logged session leaves the Watch workouts as their own visit again.
  assert.ok(!(await call(write, "edit_workout", { id: "V-1", delete: true })).isError);
  const after = (await get("/v2/training/sessions")).json.sessions.filter((x) => x.day === D);
  assert.deepEqual(after.map((x) => [x.id, x.part_count ?? 1]), [[later.uuid, 1], [walk.uuid, 3]]);
});
