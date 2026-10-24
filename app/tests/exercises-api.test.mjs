import { test } from "node:test";
import assert from "node:assert/strict";
import { app, http, one, tokens } from "./_env.mjs";
import { logSets } from "../dist/src/training.js";
import { addDays, today } from "../dist/src/time.js";

const read = tokens.createToken("ex read", "read").token;
const write = tokens.createToken("ex write", "write").token;
const T = today();
const seeded = one("SELECT COUNT(*) n FROM exercises WHERE custom=0").n;

test("catalog: every exercise with hyphen slugs, ETag, and search capped at 25", async () => {
  const r = await app.request("/v2/exercises", { headers: { authorization: `Bearer ${read}` } });
  const j = await r.json();
  assert.equal(j.count, seeded); assert.equal(j.exercises.length, seeded);
  const squat = j.exercises.find((e) => e.id === "barbell-squat");
  assert.deepEqual(squat.primary, ["quadriceps"]); assert.ok(squat.secondary.includes("lower-back")); assert.equal(squat.custom, false);
  const again = await app.request("/v2/exercises", { headers: { authorization: `Bearer ${read}`, "if-none-match": r.headers.get("etag") } });
  assert.equal(again.status, 304);
  const q = await http("GET", "/v2/exercises?q=press", { token: read });
  assert.ok(q.json.count <= 25 && q.json.count > 0);
});

test("custom create: hyphen or space muscles, count grows, since returns only newer custom ones", async () => {
  const before = new Date(Date.now() - 1000).toISOString();
  const r = await http("POST", "/v2/exercises", { token: write, json: { name: "Cable Lateral Raise", primary: ["shoulders"], secondary: ["middle-back"], equipment: "cable" } });
  assert.equal(r.status, 200, r.text);
  assert.equal(r.json.created, true); assert.deepEqual(r.json.exercise.secondary, ["middle-back"]);
  assert.equal((await http("POST", "/v2/exercises", { token: write, json: { name: "Cable Lateral Raise", primary: ["shoulders"] } })).json.created, false);
  assert.equal((await http("POST", "/v2/exercises", { token: write, json: { name: "Bad", primary: ["wings"] } })).status, 422);
  assert.equal((await http("POST", "/v2/exercises", { token: read, json: { name: "Nope", primary: ["chest"] } })).status, 403);
  const all = await http("GET", "/v2/exercises", { token: read });
  assert.equal(all.json.count, seeded + 1);
  const since = await http("GET", `/v2/exercises?since=${encodeURIComponent(before)}`, { token: read });
  assert.deepEqual(since.json.exercises.map((e) => e.id), ["custom-cable-lateral-raise"]);
  const later = await http("GET", `/v2/exercises?since=${encodeURIComponent(new Date(Date.now() + 1000).toISOString())}`, { token: read });
  assert.equal(later.json.count, 0);
});

test("detail: e1RM trend, records, structured next matching its sentence, last session", async () => {
  const sets = (day, kg) => Array.from({ length: 4 }, (_, i) => ({ exercise: "barbell-bench-press-medium-grip", weight_kg: kg, reps: 6, target_reps: 6,
    performed_at: `${day}T18:${10 + i}:00+05:30` }));
  logSets({ title: "Push", sets: [{ exercise: "bench", kind: "warmup", weight_kg: 40, reps: 10, performed_at: `${addDays(T, -14)}T18:05:00+05:30` }, ...sets(addDays(T, -14), 80)] }, "t");
  logSets({ title: "Push", sets: sets(addDays(T, -3), 82.5) }, "t");
  const r = await http("GET", "/v2/exercises/barbell-bench-press-medium-grip", { token: read });
  assert.equal(r.status, 200, r.text);
  const d = r.json;
  assert.equal(d.context_label, "BARBELL · CHEST, SHOULDERS, TRICEPS");
  assert.equal(d.e1rm.points.length, 2); assert.equal(d.e1rm.current_kg, 99); assert.equal(d.e1rm.change_8w_kg, 3);
  assert.equal(d.records.best_e1rm_kg, 99); assert.equal(d.records.heaviest_kg, 82.5);
  assert.equal(d.next.suggestion, "85 kg × 6 for 4 sets");
  assert.equal(d.next.weight_kg, 85); assert.equal(d.next.reps, 6); assert.equal(d.next.sets, 4);
  assert.ok(d.next.suggestion.includes(`${d.next.weight_kg} kg`));
  assert.equal(d.last_session.sets.length, 4); assert.equal(d.sessions_total, 2);
  assert.equal((await http("GET", "/v2/exercises/not-a-lift", { token: read })).status, 404);
});
