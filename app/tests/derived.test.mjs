import { test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { addDays, all, body, http, ingest, one, payload, tokens } from "./_env.mjs";
import { featuresRange, kcalTargetFor, markDirty, scoresFor, trainingState } from "../dist/src/derived.js";
import { dataVersions, run } from "../dist/src/db.js";
import { logSets } from "../dist/src/training.js";
import { deleteSplit, putSplit } from "../dist/src/splits.js";

const ingestToken = tokens.createToken("derived phone", "ingest").token;
const noonOf = (day) => Date.parse(`${day}T12:00:00+05:30`);
const row = (day) => one("SELECT * FROM daily_derived WHERE day=?", day);
const post = (upserts) => http("POST", "/v2/samples", { token: ingestToken, json: { schema: 1, batch_id: randomUUID(),
  client: { install_id: "t", app_version: "0.1", os: "iOS", model: "T" }, upserts, deletions: [], daily_stats: [] } });
const hrvSample = (iso, value) => ({ uuid: randomUUID(), type: "HKQuantityTypeIdentifierHeartRateVariabilitySDNN", kind: "quantity", start: iso, end: iso,
  source: { name: "Native Watch", bundle_id: "com.apple.health", version: "1", os_version: "26" }, value, unit: "ms" });

// 40 nights of synthetic history ending D: HRV and resting HR wobble so the baselines have width.
const D = "2026-05-20", START = addDays(D, -39);
ingest(body(payload(START, 40, (i) => ({ hrv: 50 + ((i % 5) - 2) * 2, rhr: 58 + ((i % 3) - 1), sleepH: 7 + ((i % 4) - 1.5) * 0.2 }))), { origin: "test" });

test("a v2 batch that changes a recent day's HRV changes that day's recovery on the next read", async () => {
  const at = noonOf(addDays(D, 1));
  const before = scoresFor(D, at);
  assert.equal(before.recovery.status, "ok");
  assert.equal(before.recovery.parts.hrv.basis, "daily");
  const v0 = dataVersions().data;
  const r = await post([hrvSample(`${D}T03:00:00.000+05:30`, 90)]);
  assert.equal(r.status, 200, r.text);
  assert.ok(dataVersions().data > v0, "each batch bumps data_version");
  const after = scoresFor(D, at);
  assert.equal(after.recovery.parts.hrv.basis, "overnight");
  assert.equal(after.recovery.parts.hrv.value, 90);
  assert.ok(after.recovery.score > before.recovery.score);
});

test("a cached score older than two days is reused until something in its window changes", () => {
  const day = addDays(D, -10), at = noonOf(D);
  const first = scoresFor(day, at);
  const cachedAt = row(day).scores_at;
  assert.ok(cachedAt); assert.equal(row(day).scores_stale, 0);
  assert.deepEqual(scoresFor(day, at), first);
  assert.equal(row(day).scores_at, cachedAt, "not recomputed");
  markDirty([addDays(day, 1)]); // after `day`: outside its window
  assert.equal(row(day).scores_stale, 0);
  markDirty([addDays(day, -5)]);
  assert.equal(row(day).scores_stale, 1);
  scoresFor(day, at);
  assert.equal(row(day).scores_stale, 0);
});

test("a change to day X marks X's features and the scores of X … X+60 stale, nothing else", () => {
  const X = "2026-03-01";
  for (const d of [addDays(X, -1), X, addDays(X, 60), addDays(X, 61)])
    run("INSERT INTO daily_derived(day,features_stale,scores_stale,features_at) VALUES(?,0,0,1) ON CONFLICT(day) DO UPDATE SET features_stale=0,scores_stale=0", d);
  const v = dataVersions().data;
  markDirty([X]);
  assert.deepEqual([addDays(X, -1), X, addDays(X, 60), addDays(X, 61)].map((d) => row(d).scores_stale), [0, 1, 1, 0]);
  assert.deepEqual([addDays(X, -1), X].map((d) => row(d).features_stale), [0, 1]);
  assert.equal(dataVersions().data, v + 1);
});

test("Health Auto Export pushes mark their days dirty too", () => {
  const day = addDays(D, -20);
  featuresRange(day, day);
  assert.equal(row(day).features_stale, 0);
  const v = dataVersions().data;
  ingest(body(payload(day, 1, () => ({ rhr: 70 }))), { origin: "test" });
  assert.equal(row(day).features_stale, 1);
  assert.equal(dataVersions().data, v + 1);
  assert.equal(featuresRange(day, day).get(day).rhr_bpm, 70);
});

test("features hold the night, wake-ups and resting HR; stages are never stored", () => {
  const f = featuresRange(D, D).get(D);
  assert.ok(f.asleep_h > 6); assert.ok(f.bedtime_min > 300); assert.ok(f.bed_h >= f.asleep_h);
  const cols = all("PRAGMA table_info(daily_derived)").map((c) => c.name);
  for (const stage of ["core_h", "deep_h", "rem_h"]) assert.equal(cols.includes(stage), false);
});

test("calorie target: the first week is the initial rule, later weeks adapt or keep last week's", () => {
  const w1 = kcalTargetFor("2026-05-11");
  assert.equal(w1.mode, "initial");
  assert.equal(w1.kcal, 2400); // trend 80 kg × 30
  assert.equal(kcalTargetFor("2026-05-11").computed_at, w1.computed_at, "stored, not recomputed");
  const w2 = kcalTargetFor("2026-05-18");
  // No week has adapted yet, so the goal-aware estimate stands (11 §8.2); the reason says why it isn't adapting.
  assert.equal(w2.mode, "initial"); assert.equal(w2.reason, "not_enough_data"); assert.equal(w2.kcal, 2400);
  const put = (k, v) => run("INSERT INTO targets(key,value_json,updated_at) VALUES(?,?,1) ON CONFLICT(key) DO UPDATE SET value_json=excluded.value_json", k, JSON.stringify(v));
  put("goal_weight_kg", 75);
  const lose = kcalTargetFor("2026-05-18", true);
  assert.equal(lose.rate_kg_week, -0.4); assert.equal(lose.kcal, 1950, "80 × 30 − 0.4 kg/week × 7700 / 7, to 50");
  put("goal", "maintain");
  assert.equal(kcalTargetFor("2026-05-18", true).kcal, 2400, "an explicit maintain overrides the goal weight");
  put("goal", "gain"); run("DELETE FROM targets WHERE key='goal_weight_kg'");
  assert.equal(kcalTargetFor("2026-05-18", true).kcal, 2600, "gain without a goal weight: +0.2 kg/week, 2,620 to 50");
  run("DELETE FROM targets WHERE key='goal'"); kcalTargetFor("2026-05-18", true);
});

test("training state: heat for all 17 muscles, splits from Settings and history, labels", () => {
  const at = noonOf("2026-05-22");
  const s = trainingState(at);
  assert.equal(Object.keys(s.heat).length, 17);
  assert.deepEqual(s.splits, [], "nothing is predefined");
  assert.equal(s.fresh_label, null);
  logSets({ title: "Legs", sets: Array.from({ length: 4 }, () => ({ exercise: "barbell-squat", weight_kg: 100, reps: 5, performed_at: "2026-05-22T11:00:00+05:30" })) }, "test");
  const after = trainingState(at);
  assert.equal(after.heat.quadriceps, 4);
  assert.equal(after.trained_today, true);
  assert.equal(after.loaded_label, "Quadriceps loaded");
  // A logged name becomes a history split with the muscles it actually trained.
  assert.deepEqual(after.splits.map((x) => [x.id, x.source, x.ready, x.muscles]), [["history:legs", "history", false, ["quadriceps"]]]);
  assert.equal(after.splits[0].exercises[0].name, "Barbell Squat");
  putSplit("push-day", { name: "Push", muscles: ["chest", "shoulders", "triceps"] });
  putSplit("legs-split", { name: "legs", muscles: ["quadriceps", "hamstrings"] });
  const both = trainingState(at);
  assert.deepEqual(both.splits.map((x) => [x.id, x.source, x.ready]), [["push-day", "defined", true], ["legs-split", "defined", false]],
    "a defined split takes over the history split of the same name");
  assert.equal(both.splits[1].exercises[0].name, "Barbell Squat", "a defined split's exercises come from its last session by name");
  assert.equal(both.fresh_label, "Push fresh");
  deleteSplit("push-day"); deleteSplit("legs-split");
});
