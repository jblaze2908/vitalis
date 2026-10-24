import "./_env.mjs";
import { test } from "node:test";
import assert from "node:assert/strict";
const T = await import("../dist/src/training-analytics.js");
const { e1rm } = await import("../dist/src/training.js");

const NOW = Date.parse("2026-10-24T04:00:00Z");
const TODAY = "2026-10-24";
const IST = 330;
const H = 3_600_000;
const r3 = (v) => Math.round(v * 1000) / 1000;

// n synthetic working sets, `hoursAgo` before NOW.
function sets(n, hoursAgo, { primary = ["quadriceps"], secondary = [], kind = "normal", session = "s1", exercise = "barbell-squat" } = {}) {
  return Array.from({ length: n }, () => ({ session_id: session, exercise_id: exercise, kind, performed_at: NOW - hoursAgo * H,
    tz_offset_min: IST, weight_kg: 100, reps: 5, primary, secondary }));
}
const keys17 = (o) => assert.deepEqual(Object.keys(o).sort(), [...T.SLUGS].sort());

test("slugs: 17, hyphenated, round-trip", () => {
  assert.equal(T.SLUGS.length, 17);
  assert.equal(T.toSlug("lower back"), "lower-back");
  assert.equal(T.fromSlug("middle-back"), "middle back");
  for (const s of T.SLUGS) assert.equal(T.toSlug(T.fromSlug(s)), s);
});

const VECTORS = [
  [4, 0, 4.0, 4], [4, 12, 2.866, 3], [4, 24, 2.054, 3], [4, 36, 1.472, 2], [4, 48, 1.054, 2], [4, 72, 0.541, 2],
  [4, 84, 0.388, 1], [4, 168, 0.038, 1],
  [8, 24, 4.107, 4], [8, 48, 2.109, 3], [8, 72, 1.083, 2], [8, 96, 0.556, 2], [8, 108, 0.398, 1],
];
for (const [n, h, L, heat] of VECTORS) {
  test(`§10.5: ${n} primary at ${h} h → L ${L}, heat ${heat}`, () => {
    const xs = sets(n, h);
    assert.equal(r3(T.muscleLoad(xs, NOW).quadriceps), L);
    assert.equal(T.freshness(xs, NOW, TODAY).quadriceps.heat, heat);
  });
}

test("§10.5: 4 primary + 4 secondary at 26 h, plus 4 primary at 98 h → 3.177 / 3", () => {
  const xs = [...sets(4, 26), ...sets(4, 26, { primary: ["hamstrings"], secondary: ["quadriceps"] }), ...sets(4, 98)];
  assert.equal(r3(T.muscleLoad(xs, NOW).quadriceps), 3.177);
  assert.equal(T.freshness(xs, NOW, TODAY).quadriceps.heat, 3);
});

test("§10.5: nothing in 30 days → 0 / 0; 15–30 days ago → load 0 but heat 1", () => {
  const f0 = T.freshness([], NOW, TODAY);
  keys17(f0);
  for (const m of T.SLUGS) assert.deepEqual(f0[m], { heat: 0, load: 0, days_since: null });
  const old = sets(4, 31 * 24);
  assert.equal(T.muscleLoad(old, NOW).quadriceps, 0);
  assert.equal(T.freshness(old, NOW, TODAY).quadriceps.heat, 0);
  const mid = sets(4, 20 * 24);
  assert.equal(T.muscleLoad(mid, NOW).quadriceps, 0);
  assert.equal(T.freshness(mid, NOW, TODAY).quadriceps.heat, 1);
});

test("heat band edges", () => {
  assert.equal(T.heat(0, false), 0);
  assert.equal(T.heat(9, false), 0);
  assert.equal(T.heat(0, true), 1);
  assert.equal(T.heat(0.4999, true), 1);
  assert.equal(T.heat(0.5, true), 2);
  assert.equal(T.heat(2, true), 3);
  assert.equal(T.heat(4, true), 4);
});

test("warm-ups and future sets are ignored; bodyweight sets count", () => {
  assert.equal(T.muscleLoad(sets(4, 0, { kind: "warmup" }), NOW).quadriceps, 0);
  assert.equal(T.muscleLoad(sets(4, -1), NOW).quadriceps, 0);
  const bw = sets(4, 0).map((s) => ({ ...s, weight_kg: null }));
  assert.equal(T.muscleLoad(bw, NOW).quadriceps, 4);
});

test("freshness: 17 keys, load to 2 dp, days_since counts local days from primary sets only", () => {
  const xs = [...sets(4, 84), ...sets(2, 24, { primary: ["chest"], secondary: ["lower back"] })];
  const f = T.freshness(xs, NOW, TODAY);
  keys17(f);
  assert.equal(f.quadriceps.load, 0.39);
  assert.equal(f.quadriceps.days_since, 4); // 84 h before 09:30 IST on the 24th = 21:30 IST on the 20th
  assert.equal(f.chest.days_since, 1);
  assert.equal(f["lower-back"].days_since, null);
  assert.equal(f["lower-back"].heat, 2);
  assert.equal(f.neck.days_since, null);
});

const fresh = (over = {}) => Object.fromEntries(T.SLUGS.map((m) => [m, { heat: 1, load: 0, days_since: 3, ...over[m] }]));

test("dueTemplate: null when nothing fully fresh", () => {
  assert.equal(T.dueTemplate(fresh({ quadriceps: { heat: 2 }, chest: { heat: 3 }, lats: { heat: 2 } })), null);
});

test("dueTemplate: largest min(days_since); null counts as infinite; ties in table order", () => {
  assert.equal(T.dueTemplate(fresh()).template, "legs");
  const pull = T.dueTemplate(fresh({ quadriceps: { heat: 2 }, lats: { days_since: 9 }, "middle-back": { days_since: 7 }, biceps: { days_since: 8 } }));
  assert.deepEqual(pull, { template: "pull", name: "Pull", days_since: 7,
    exercises: ["wide-grip-lat-pulldown", "bent-over-barbell-row", "seated-cable-rows", "face-pull", "barbell-curl"] });
  const never = T.dueTemplate(fresh({ chest: { days_since: null }, shoulders: { days_since: null }, triceps: { days_since: null } }));
  assert.equal(never.template, "push");
  assert.equal(never.days_since, null);
  // Push and pull both never trained (legs ready at 3 loses to infinity): push comes first in the table.
  const tie = T.dueTemplate(fresh({ quadriceps: { heat: 0 }, chest: { days_since: null }, shoulders: { days_since: null }, triceps: { days_since: null },
    lats: { days_since: null }, "middle-back": { days_since: null }, biceps: { days_since: null } }));
  assert.equal(tie.template, "push");
});

test("dueTemplate: last matching session's exercises (deduped, in order) override defaults", () => {
  const d = T.dueTemplate(fresh(), { legs: ["leg-press", "barbell-squat", "leg-press"] });
  assert.deepEqual(d.exercises, ["leg-press", "barbell-squat"]);
  assert.equal(T.dueTemplate(fresh(), { legs: [] }).exercises[0], "barbell-squat");
});

test("labels", () => {
  assert.equal(T.freshLabel(T.dueTemplate(fresh())), "Legs fresh");
  assert.equal(T.freshLabel(null), null);
  assert.equal(T.loadedLabel(fresh()), null);
  assert.equal(T.loadedLabel(fresh({ chest: { heat: 4, load: 5 }, triceps: { heat: 3, load: 3 } })), "Chest loaded");
  assert.equal(T.loadedLabel(fresh({ "lower-back": { heat: 3, load: 2.5 }, triceps: { heat: 3, load: 2.1 } })), "Lower back loaded");
  assert.equal(T.loadedLabel(fresh({ triceps: { heat: 3, load: 2 }, chest: { heat: 3, load: 2 } })), "Chest loaded");
});

test("sessionHeat: ≥4 → 4, ≥2 → 3, >0 → 2, 0 → 0; 17 keys", () => {
  const xs = [...sets(4, 1, { primary: ["chest"], secondary: ["shoulders", "triceps"] }), ...sets(1, 1, { primary: ["triceps"] }),
    ...sets(1, 1, { primary: ["biceps"], kind: "warmup" }), ...sets(1, 1, { primary: ["forearms"], kind: "drop" })];
  const h = T.sessionHeat(xs);
  keys17(h);
  assert.equal(h.chest, 4);
  assert.equal(h.shoulders, 3);
  assert.equal(h.triceps, 3);
  assert.equal(h.forearms, 2);
  assert.equal(h.biceps, 0);
  assert.equal(h.quadriceps, 0);
});

test("weeklySets: Monday week, 0.5 secondary, status and muscles_hit", () => {
  assert.equal(T.weekStartOf("2026-10-24"), "2026-10-19");
  assert.equal(T.weekStartOf("2026-10-19"), "2026-10-19");
  assert.equal(T.weekStartOf("2026-10-25"), "2026-10-19");
  const xs = [
    ...sets(11, 30, { primary: ["chest"], secondary: ["triceps"] }),
    ...sets(21, 30, { primary: ["quadriceps"] }),
    ...sets(1, 30, { primary: ["biceps"], secondary: ["forearms"] }),
    ...sets(3, 30, { primary: ["lats"], kind: "warmup" }),
    ...sets(5, 7 * 24, { primary: ["hamstrings"] }), // previous week
  ];
  const w = T.weeklySets(xs, "2026-10-19");
  keys17(w.by_muscle);
  keys17(w.status);
  assert.equal(w.by_muscle.chest, 11);
  assert.equal(w.by_muscle.triceps, 5.5);
  assert.equal(w.by_muscle.forearms, 0.5);
  assert.equal(w.by_muscle.lats, 0);
  assert.equal(w.by_muscle.hamstrings, 0);
  assert.deepEqual([w.status.chest, w.status.quadriceps, w.status.triceps], ["in_range", "over", "under"]);
  assert.equal(w.muscles_hit, 4); // chest, triceps, quadriceps, biceps; forearms 0.5 < 1
  assert.equal(w.muscles_total, 17);
  assert.deepEqual([w.min, w.max], [10, 20]);
  assert.equal(T.weeklySets(xs, "2026-10-19", { min: 12, max: 15 }).status.chest, "under");
});

test("§10.5 e1RM via existing e1rm()", () => {
  for (const [w, r, want] of [[100, 6, 120], [82.5, 6, 99], [100, 1, 100], [60, 12, 84], [60, 13, null], [0, 5, null], [100, 0, null], [20, 10, 26.7]])
    assert.equal(e1rm(w, r), want, `${w} × ${r}`);
});

test("e1rmTrend: 84-day points, 56-day change, null with < 2 points", () => {
  const pts = [
    { day: "2026-07-01", kg: 80, session_id: "old" },     // > 84 days ago
    { day: "2026-08-15", kg: 90, session_id: "a" },       // in 84, not in 56
    { day: "2026-09-01", kg: 95.9, session_id: "b" },
    { day: "2026-09-01", kg: 94, session_id: "b" },        // same session, lower: dropped
    { day: "2026-10-22", kg: 99, session_id: "c" },
    { day: "2026-10-25", kg: 120, session_id: "future" },
  ];
  const t = T.e1rmTrend(pts, TODAY);
  assert.deepEqual(t.points.map((p) => p.session_id), ["a", "b", "c"]);
  assert.equal(t.current_kg, 99);
  assert.equal(t.change_8w_kg, 3.1);
  assert.equal(t.estimate, true);
  assert.equal(T.e1rmTrend(pts.filter((p) => p.session_id !== "b"), TODAY).change_8w_kg, null);
  assert.deepEqual(T.e1rmTrend([], TODAY), { current_kg: null, change_8w_kg: null, points: [], estimate: true });
});

test("templates reference catalog exercises and slug muscles", async () => {
  const { getExercise } = await import("../dist/src/exercises.js");
  for (const t of T.TEMPLATES) {
    for (const id of t.exercises) assert.ok(getExercise(id), id);
    for (const m of t.muscles) assert.ok(T.SLUGS.includes(m), m);
  }
});
