import { test } from "node:test";
import assert from "node:assert/strict";
import { http, one, tokens } from "./_env.mjs";
import { addDays, today } from "../dist/src/time.js";

const write = tokens.createToken("watch relay", "write").token;
const read = tokens.createToken("w read", "read").token;
const T = addDays(today(), -1);
const at = (hm) => `${T}T${hm}:00+05:30`;
const session = (extra = {}) => ({ client_id: "S-1", title: "Legs", template: "legs", source: "watch", started_at: at("18:40"), ended_at: null, tz_offset_min: 330, ...extra });
const sets = [
  { id: "A1", exercise: "barbell-squat", kind: "warmup", weight_kg: 60, reps: 8, performed_at: at("18:44") },
  { id: "A2", exercise: "barbell-squat", kind: "normal", weight_kg: 100, reps: 6, target_weight_kg: 100, target_reps: 6, rpe: null, performed_at: at("18:47") },
  { id: "A3", exercise: "squat", weight_kg: 100, reps: 6, performed_at: at("18:51") },
];
const post = (json, token = write) => http("POST", "/v2/workouts", { token, json });

test("posting the same body three times creates one session and N sets", async () => {
  let r;
  for (let i = 0; i < 3; i++) { r = await post({ session: session(), sets }); assert.equal(r.status, 200, r.text); }
  assert.deepEqual(r.json.accepted, { inserted: 0, updated: 0, deleted: 0, unchanged: 3 });
  assert.equal(one("SELECT COUNT(*) n FROM sessions").n, 1);
  assert.equal(one("SELECT COUNT(*) n FROM sets WHERE session_id='S-1'").n, 3);
  const s = one("SELECT * FROM sessions WHERE id='S-1'");
  assert.equal(s.client_source, "watch"); assert.equal(s.template, "legs"); assert.equal(s.source, "rest:watch relay");
  assert.equal(r.json.session.working_sets, 2); assert.equal(r.json.session.heat.quadriceps, 3);
});

test("changing one set's reps updates it; deleted: true removes it from reads; ended_at and hk link update", async () => {
  let r = await post({ session: session({ ended_at: at("19:30"), hk_workout_uuid: "HKW-9" }), sets: [{ ...sets[2], reps: 5 }, { id: "A1", deleted: true }] });
  assert.deepEqual(r.json.accepted, { inserted: 0, updated: 1, deleted: 1, unchanged: 0 });
  assert.equal(one("SELECT reps FROM sets WHERE id='A3'").reps, 5);
  assert.equal(r.json.session.exercises[0].sets.length, 2);
  assert.equal(r.json.session.end, `${T}T19:30:00+05:30`);
  assert.equal(one("SELECT hk_workout_uuid h FROM sessions WHERE id='S-1'").h, "HKW-9");
  r = await post({ session: session(), sets: [{ id: "A1", deleted: true }] });
  assert.deepEqual(r.json.accepted, { inserted: 0, updated: 0, deleted: 0, unchanged: 1 });
});

test("a set id from another session is 409 and nothing is written", async () => {
  const before = one("SELECT COUNT(*) n FROM sets").n;
  const r = await post({ session: session({ client_id: "S-2" }), sets: [{ id: "NEW-1", exercise: "barbell-squat", weight_kg: 50, reps: 5, performed_at: at("20:00") }, { ...sets[1] }] });
  assert.equal(r.status, 409); assert.equal(r.json.code, "conflict");
  assert.equal(one("SELECT COUNT(*) n FROM sets").n, before);
  assert.equal(one("SELECT * FROM sessions WHERE id='S-2'"), undefined, "the session insert rolled back too");
});

test("an unclear exercise name is 422 with candidates and nothing is written", async () => {
  const r = await post({ session: session({ client_id: "S-3" }), sets: [{ id: "U1", exercise: "press", weight_kg: 40, reps: 8, performed_at: at("20:10") }] });
  assert.equal(r.status, 422); assert.equal(r.json.code, "invalid");
  assert.ok(Array.isArray(r.json.candidates) && r.json.candidates[0].candidates.length > 0);
  assert.equal(one("SELECT * FROM sessions WHERE id='S-3'"), undefined);
});

test("PRs come back from the server; validation and scope", async () => {
  const r = await post({ session: session({ client_id: "S-4", started_at: `${today()}T07:00:00+05:30` }),
    sets: [{ id: "P1", exercise: "barbell-squat", weight_kg: 110, reps: 6, performed_at: `${today()}T07:05:00+05:30` }] });
  assert.equal(r.status, 200, r.text);
  assert.equal(r.json.prs.length, 1);
  assert.equal(r.json.prs[0].exercise_id, "barbell-squat"); assert.equal(r.json.prs[0].previous_best_estimate, 120);
  assert.equal(r.json.prs[0].e1rm_kg_estimate, 132);
  assert.equal((await post({ session: session({ source: "tablet" }), sets: [] })).status, 422);
  assert.equal((await post({ session: session(), sets: Array.from({ length: 201 }, (_, i) => ({ id: `x${i}`, deleted: true })) })).status, 422);
  assert.equal((await post({ session: session(), sets: [] }, read)).status, 403);
  const t = await http("GET", `/v2/training/sessions/S-4`, { token: read });
  assert.equal(t.json.client_source, "watch");
});
