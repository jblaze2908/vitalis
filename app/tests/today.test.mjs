import { test } from "node:test";
import assert from "node:assert/strict";
import { addDays, body, http, ingest, payload, tokens } from "./_env.mjs";
import { digestBody, todayBody } from "../dist/src/today.js";
import { markDirty } from "../dist/src/derived.js";
import { run, tx } from "../dist/src/db.js";

const read = tokens.createToken("today read", "read").token;
const ingestTok = tokens.createToken("today ingest", "ingest").token;
const at = (day, hm) => Date.parse(`${day}T${hm}:00+05:30`);

// Same shape as mcp.test.mjs: 35 steady days, then a short late night with poor heart numbers.
const BAD = "2026-08-31";
ingest(body(payload(addDays(BAD, -35), 36, (i, d) => d === BAD
  ? { sleepH: 4.9, bed: "02:51", rhr: 73, hrv: 36 }
  : { sleepH: 7 + ((i % 5) - 2) * 0.1, rhr: 60 + ((i % 3) - 1), hrv: 50 + ((i % 4) - 2), bed: i % 2 ? "23:20" : "23:40", weight: 80 - i * 0.02 })), { origin: "test" });

// A good night after 40 steady ones, nothing trained yet.
const GOOD = "2026-02-20";
ingest(body(payload(addDays(GOOD, -40), 41, (i, d) => d === GOOD ? { hrv: 56, rhr: 57 } : { hrv: 50, rhr: 60 })), { origin: "test" });

test("after a short late night: recovery is rest and the one action is to log a meal", () => {
  const t = todayBody(BAD, at(BAD, "09:41"));
  assert.equal(t.recovery.status, "ok");
  assert.equal(t.recovery.band, "rest");
  assert.equal(t.verdict.headline, "Rest today");
  assert.equal(t.verdict.action.kind, "log_meal");
  assert.equal(t.fuel.next_slot, "breakfast");
  assert.equal(t.fuel.next_label, "LOG BREAKFAST");
  assert.equal(Object.keys(t.training.heat).length, 17);
  assert.equal(t.recovery.parts.resting_hr.tint, "watch");
  assert.equal(t.generated_at, "2026-08-31T09:41:00+05:30");
});

test("a good night, no splits yet: Train hard today, naming none", () => {
  const t = todayBody(GOOD, at(GOOD, "09:41"));
  assert.equal(t.recovery.band, "ready", JSON.stringify(t.recovery));
  assert.equal(t.verdict.headline, "Train hard today");
  assert.deepEqual(t.verdict.action, { kind: "start_workout", label: "Start workout", template: null, intensity: "normal" });
  assert.equal(t.training.due, null);
  assert.deepEqual(t.training.splits, []);
  assert.equal(t.training.fresh_label, null);
  assert.equal(t.training.heat.quadriceps, 0, "no data yet");
});

test("pulse window runs from today's wake to bed-by; events after now are omitted", () => {
  const t = todayBody(GOOD, at(GOOD, "09:41"));
  assert.equal(t.pulse.window.start, `${GOOD}T06:50:00+05:30`);
  assert.equal(t.pulse.events[0].kind, "wake");
  assert.equal(t.pulse.now, `${GOOD}T09:41:00+05:30`);
  assert.ok(t.pulse.window.end > t.pulse.window.start);
});

test("the digest is available only 30 minutes after the night ended", () => {
  assert.equal(digestBody(GOOD, at(GOOD, "07:10")).available, false);
  const d = digestBody(GOOD, at(GOOD, "07:21"));
  assert.equal(d.available, true);
  assert.equal(d.night_ended_at, `${GOOD}T06:50:00+05:30`);
  assert.deepEqual(d.headline, ["You slept well.", "Ready to push."]);
  assert.equal(d.date_label, "FRI 20 FEB");
  assert.equal(d.greeting, "GOOD MORNING");
  assert.deepEqual(d.sleep.rows.map((r) => r.key), ["duration", "bedtime", "efficiency", "wakeups"]);
  assert.equal(d.sleep.rows[0].value, "7H00");
  assert.equal(d.sleep.rows[1].delta, "ON TIME");
  assert.equal(d.plan[0].kind, "train"); assert.equal(d.plan[0].title, "Train"); assert.equal(d.plan[0].reason, "PICK AS YOU GO");
  assert.equal(d.plan.length, 3);
  const none = digestBody("2025-01-01", at("2025-01-01", "09:00"));
  assert.equal(none.available, false); assert.equal(none.sleep, null); assert.equal(none.recovery, null);
  assert.deepEqual(none.headline, ["Morning.", "Let's see how today goes."]);
});

test("GET /v2/today: read scope, ETag with 304, and a food write changes the ETag", async () => {
  assert.equal((await http("GET", "/v2/today", { token: ingestTok })).status, 403);
  const a = await http("GET", "/v2/today", { token: read });
  assert.equal(a.status, 200, a.text);
  const r1 = await (await import("./_env.mjs")).app.request("/v2/today", { headers: { authorization: `Bearer ${read}` } });
  const etag = r1.headers.get("etag");
  const again = await (await import("./_env.mjs")).app.request("/v2/today", { headers: { authorization: `Bearer ${read}`, "if-none-match": etag } });
  assert.equal(again.status, 304);
  const day = a.json.day;
  tx(() => {
    run(`INSERT INTO food_entries(id,meal_id,day,slot,eaten_at,tz_offset_min,name,kcal,source,created_at,updated_at) VALUES('f1','m1',?,'lunch',?,330,'Dal',300,'manual',1,1)`, day, Date.now());
    markDirty([day]);
  });
  const b = await (await import("./_env.mjs")).app.request("/v2/today", { headers: { authorization: `Bearer ${read}`, "if-none-match": etag } });
  assert.equal(b.status, 200);
  assert.equal((await b.json()).fuel.kcal_eaten, 300);
  assert.equal((await http("GET", "/v2/digest", { token: read })).status, 200);
  assert.equal((await http("GET", "/v2/today?date=2999-01-01", { token: read })).status, 400);
});

test("no splits yet but a muscle is loaded: Muscles still loaded, not Train hard", async () => {
  const { logSets } = await import("../dist/src/training.js");
  const sets = Array.from({ length: 6 }, (_, i) => ({ exercise: "barbell-squat", weight_kg: 100, reps: 5, performed_at: `${addDays(GOOD, -1)}T18:${String(10 + i).padStart(2, "0")}:00+05:30` }));
  const id = logSets({ title: "Workout", sets }, "test").session.id;
  const t = todayBody(GOOD, at(GOOD, "09:41"));
  assert.deepEqual(t.training.splits, [], "a generic title is not a split");
  assert.equal(t.training.loaded_label, "Quadriceps loaded");
  assert.equal(t.verdict.headline, "Muscles still loaded");
  run("UPDATE sets SET deleted_at=1 WHERE session_id=?", id); run("UPDATE sessions SET deleted_at=1 WHERE id=?", id); markDirty([addDays(GOOD, -1), GOOD]);
});
