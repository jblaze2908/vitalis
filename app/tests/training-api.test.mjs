import { test } from "node:test";
import assert from "node:assert/strict";
import { http, tokens } from "./_env.mjs";
import { run } from "../dist/src/db.js";
import { logSets } from "../dist/src/training.js";
import { addDays, today } from "../dist/src/time.js";

const read = tokens.createToken("train read", "read").token;
const T = today();
const iso = (day, hm) => `${day}T${hm}:00+05:30`;
const bench = (day, kg, n = 3) => Array.from({ length: n }, (_, i) => ({ exercise: "bench", weight_kg: kg, reps: 5, performed_at: iso(day, `18:${String(10 + i).padStart(2, "0")}`) }));

test("a fresh install says empty and still returns 17 muscles and a due template", async () => {
  const r = await http("GET", "/v2/training", { token: read });
  assert.equal(r.status, 200, r.text);
  assert.equal(r.json.empty, true);
  assert.equal(Object.keys(r.json.heat).length, 17); assert.equal(r.json.muscles.length, 17);
  assert.equal(r.json.due.template, "legs"); assert.equal(r.json.due.exercise_count, 5);
  assert.deepEqual(r.json.sessions, []);
  assert.match(r.json.label, /^THIS WEEK · \d+ TO \d+ [A-Z]{3}$/);
});

test("sessions list with PR tags; detail with heat, PR flags and top sets", async () => {
  const a = logSets({ title: "Push", sets: bench(addDays(T, -9), 80) }, "test").session.id;
  const b = logSets({ title: "Push", sets: [{ exercise: "bench", kind: "warmup", weight_kg: 40, reps: 10, performed_at: iso(addDays(T, -2), "18:05") }, ...bench(addDays(T, -2), 85)] }, "test").session.id;
  const h = await http("GET", "/v2/training/sessions", { token: read });
  const rows = Object.fromEntries(h.json.sessions.map((s) => [s.id, s]));
  assert.equal(rows[a].tag, null, "first time is not a PR");
  assert.deepEqual(rows[b].tag, { kind: "pr", label: "PR · BENCH" });
  const d = await http("GET", `/v2/training/sessions/${b}`, { token: read });
  assert.equal(d.status, 200, d.text);
  assert.equal(d.json.heat.chest, 3); assert.equal(Object.keys(d.json.heat).length, 17);
  assert.equal(d.json.exercises[0].pr, true); assert.equal(d.json.exercises[0].summary, "3 SETS · TOP 85 X 5");
  assert.equal(d.json.exercises[0].sets[0].kind, "warmup"); assert.equal(d.json.working_sets, 3);
  assert.match(d.json.context_label, /^[A-Z]{3} \d+ [A-Z]{3} · 18:05 · \d+ MIN$/);
  assert.equal((await http("GET", "/v2/training/sessions/nope", { token: read })).status, 404);
});

test("a session linked by hk_workout_uuid shows that workout's heart rate even when times don't overlap", async () => {
  run(`INSERT INTO hk_workouts(id,name,start,end,start_ms,end_ms,day,duration_s,hr_avg,hr_max,updated_at) VALUES('HKW-1','traditionalStrengthTraining',
    '2020-01-01T10:00:00+05:30','2020-01-01T11:00:00+05:30',?,?, '2020-01-01',3600,121,150,1)`, Date.parse("2020-01-01T10:00:00+05:30"), Date.parse("2020-01-01T11:00:00+05:30"));
  const id = logSets({ title: "Legs", sets: [{ exercise: "squat", weight_kg: 100, reps: 5, performed_at: iso(addDays(T, -1), "07:00") }] }, "test").session.id;
  run("UPDATE sessions SET hk_workout_uuid='HKW-1' WHERE id=?", id);
  const d = await http("GET", `/v2/training/sessions/${id}`, { token: read });
  assert.deepEqual(d.json.watch, { workout_id: "HKW-1", hr_avg: 121, hr_max: 150 });
  assert.equal(d.json.avg_bpm, 121);
});

test("pagination returns each session once, newest first", async () => {
  for (let i = 12; i <= 40; i += 4) logSets({ title: `S${i}`, sets: [{ exercise: "curl", weight_kg: 30, reps: 10, performed_at: iso(addDays(T, -i), "08:00") }] }, "test");
  const seen = []; let next = null, pages = 0;
  do {
    const r = await http("GET", `/v2/training/sessions?limit=3${next ? `&before=${next}` : ""}`, { token: read });
    assert.equal(r.status, 200, r.text);
    seen.push(...r.json.sessions.map((s) => s.start)); next = r.json.next; pages++;
  } while (next && pages < 20);
  assert.equal(seen.length, new Set(seen).size, "no duplicates");
  assert.equal(seen.length, 11);
  assert.deepEqual([...seen].sort().reverse(), seen);
  assert.equal((await http("GET", "/v2/training/sessions?limit=99", { token: read })).status, 400);
  assert.equal((await http("GET", "/v2/training/sessions?before=zzz", { token: read })).status, 400);
});

test("the week body counts this week's work", async () => {
  const r = await http("GET", `/v2/training?week=${addDays(T, -2)}`, { token: read });
  assert.equal(r.json.empty, false);
  assert.ok(r.json.sessions.length >= 1);
  assert.ok(r.json.weekly_sets.by_muscle.chest >= 0);
});
