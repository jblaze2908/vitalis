import { test } from "node:test";
import assert from "node:assert/strict";
import { call, http, one, tokens } from "./_env.mjs";
import { addDays, today } from "../dist/src/time.js";

// Devices post the whole session each time; an edit made elsewhere must survive their next post.
const agent = tokens.createToken("coach", "write").token, phone = tokens.createToken("iphone", "write").token;
const T = addDays(today(), -1), at = (hm) => `${T}T${hm}:00+05:30`;
const session = (id, extra = {}) => ({ client_id: id, title: "Push", source: "phone", started_at: at("18:40"), ended_at: null, tz_offset_min: 330, ...extra });
const set = (id, hm, extra = {}) => ({ id, exercise: "barbell-bench-press-medium-grip", weight_kg: 60, reps: 8, performed_at: at(hm), ...extra });
const post = (s, sets) => http("POST", "/v2/workouts", { token: phone, json: { session: s, sets } });
const exerciseOf = (id) => one("SELECT exercise_id e FROM sets WHERE id=?", id).e;
const shown = async (sid) => (await call(agent, "get_workout", { id: sid })).data.exercises.flatMap((e) => e.sets.map((x) => `${x.id}:${e.exercise_id}:${x.reps}`));

test("an agent's exercise change survives the device posting its stale snapshot, and the reply says what was saved", async () => {
  const s = session("E-1");
  assert.equal((await post(s, [set("E1-a", "18:45")])).status, 200);
  const e = await call(agent, "edit_set", { id: "E1-a", exercise: "dumbbell bench press" });
  assert.equal(e.isError, false, e.text);
  assert.deepEqual(e.data.exercise, { id: "dumbbell-bench-press", name: "Dumbbell Bench Press" });
  assert.deepEqual(e.data.changed, ["exercise_id"]);
  assert.equal(e.data.session_id, "E-1");

  const r = await post(s, [set("E1-a", "18:45"), set("E1-b", "18:50")]);
  assert.deepEqual(r.json.accepted, { inserted: 1, updated: 0, deleted: 0, unchanged: 1 });
  assert.equal(exerciseOf("E1-a"), "dumbbell-bench-press");
  assert.deepEqual(await shown("E-1"), ["E1-a:dumbbell-bench-press:8", "E1-b:barbell-bench-press-medium-grip:8"]);
});

test("a device edit applies only the fields it changed: reps change, the agent's exercise stays", async () => {
  const s = session("E-1");
  const r = await post(s, [set("E1-a", "18:45", { reps: 9 }), set("E1-b", "18:50")]);
  assert.deepEqual(r.json.accepted, { inserted: 0, updated: 1, deleted: 0, unchanged: 1 });
  assert.deepEqual({ ...one("SELECT exercise_id e, reps FROM sets WHERE id='E1-a'") }, { e: "dumbbell-bench-press", reps: 9 });
  // The device moving it to another exercise is its own edit, and wins.
  await post(s, [set("E1-a", "18:45", { reps: 9, exercise: "incline bench press" }), set("E1-b", "18:50")]);
  assert.notEqual(exerciseOf("E1-a"), "dumbbell-bench-press");
});

test("deletes: an agent's delete survives an unchanged repost; a device undo revives; an agent's restore survives the device's old delete marker", async () => {
  const s = session("E-2", { started_at: at("06:00") });
  const base = [set("E2-a", "06:05"), set("E2-b", "06:10")];
  await post(s, base);
  assert.equal((await call(agent, "edit_set", { id: "E2-a", delete: true })).data.deleted, true);
  await post(s, base);
  assert.notEqual(one("SELECT deleted_at d FROM sets WHERE id='E2-a'").d, null);

  await post(s, [base[0], { id: "E2-b", deleted: true }]);
  assert.notEqual(one("SELECT deleted_at d FROM sets WHERE id='E2-b'").d, null);
  await post(s, base); // undo on the device: the set comes back
  assert.equal(one("SELECT deleted_at d FROM sets WHERE id='E2-b'").d, null);

  await post(s, [base[0], { id: "E2-b", deleted: true }]);
  assert.equal((await call(agent, "edit_set", { id: "E2-b", restore: true })).isError, false);
  await post(s, [base[0], { id: "E2-b", deleted: true }]);
  assert.equal(one("SELECT deleted_at d FROM sets WHERE id='E2-b'").d, null);
});

test("PATCH /v2/sets/:id edits any set of a finished session and returns the session as the app shows it", async () => {
  const s = session("E-3", { started_at: at("12:00"), ended_at: at("13:00") });
  await post(s, [set("E3-a", "12:05"), set("E3-b", "12:10"), set("E3-c", "12:15")]);
  const r = await http("PATCH", "/v2/sets/E3-a", { token: phone, json: { exercise: "dumbbell-bench-press", kind: "warmup", weight_kg: 20, note: "wrong machine" } });
  assert.equal(r.status, 200, r.text);
  assert.deepEqual(r.json.set.exercise, { id: "dumbbell-bench-press", name: "Dumbbell Bench Press" });
  assert.equal(r.json.set.kind, "warmup"); assert.equal(r.json.set.note, "wrong machine");
  assert.equal(r.json.session.id, "E-3");

  const d = await http("PATCH", "/v2/sets/E3-b", { token: phone, json: { delete: true } });
  assert.equal(d.json.set.deleted, true);
  assert.deepEqual(await shown("E-3"), ["E3-a:dumbbell-bench-press:8", "E3-c:barbell-bench-press-medium-grip:8"]);
  assert.equal((await http("PATCH", "/v2/sets/E3-b", { token: phone, json: { restore: true } })).status, 200);
  assert.equal((await http("PATCH", "/v2/sets/nope", { token: phone, json: { reps: 5 } })).status, 404);
  assert.equal((await http("PATCH", "/v2/sets/E3-a", { token: phone, json: { reps: -1 } })).status, 422);
});

test("aggregates follow edits and deletes: volume, working sets, best set and records", async () => {
  const s = session("E-4", { started_at: at("15:00") });
  await post(s, [set("E4-a", "15:05", { weight_kg: 100, reps: 5 }), set("E4-b", "15:10", { weight_kg: 60, reps: 8 })]);
  let w = (await call(agent, "get_workout", { id: "E-4" })).data;
  assert.equal(w.volume_kg, 980); assert.equal(w.exercises[0].best_set, "100 kg × 5");
  await call(agent, "edit_set", { id: "E4-a", delete: true });
  w = (await call(agent, "get_workout", { id: "E-4" })).data;
  assert.equal(w.volume_kg, 480); assert.equal(w.working_sets, 1); assert.equal(w.exercises[0].best_set, "60 kg × 8");
  await call(agent, "edit_set", { id: "E4-b", exercise: "dumbbell bench press" });
  w = (await call(agent, "get_workout", { id: "E-4" })).data;
  assert.deepEqual(w.exercises.map((e) => e.exercise_id), ["dumbbell-bench-press"]);
});
