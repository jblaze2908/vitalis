// 11 §10.6 vectors; fuel.ts is pure, so no database harness.
import { test } from "node:test";
import assert from "node:assert/strict";
const { weightTrend, monthChange, adaptiveKcal, goalRate, initialKcal, measuredBurn, proteinTarget, stepsTarget, round5, round10, round50, round500 } =
  await import("../dist/src/fuel.js");

const WEIGHTS = [76.8, null, 76.6, 76.9, null, 76.5, 76.4, 76.7, null, 76.3, 76.2, null, 76.4, 76.1, 76.0, null, 76.2, 75.9, null, 76.0, 75.8];
const TREND = [76.89, 76.89, 76.861, 76.865, 76.865, 76.828, 76.786, 76.777, 76.777, 76.729, 76.676, 76.676, 76.649, 76.594, 76.534,
  76.534, 76.501, 76.441, 76.441, 76.397, 76.337];
const INTAKES = [2250, 2310, 2180, 2400, 900, 2290, 2350, 2200, 2260, null, 2300, 2280, 2190, 2330, 2240, 2270, 2210, 2350, 2300, null, 2250];
const r3 = (v) => Math.round(v * 1000) / 1000;

test("weight trend matches the 21-day vector to 3 decimals", () => {
  assert.deepEqual(weightTrend(WEIGHTS, 76.9).map(r3), TREND);
});

test("weight trend: object form, no seed uses first weigh-in, no weigh-ins is null", () => {
  const days = WEIGHTS.slice(0, 3).map((kg, i) => ({ day: `2026-10-0${i + 1}`, kg }));
  assert.deepEqual(weightTrend(days, 76.9).map((d) => ({ ...d, trend_kg: r3(d.trend_kg) })), [
    { day: "2026-10-01", raw_kg: 76.8, trend_kg: 76.89 }, { day: "2026-10-02", raw_kg: null, trend_kg: 76.89 },
    { day: "2026-10-03", raw_kg: 76.6, trend_kg: 76.861 }]);
  assert.deepEqual(weightTrend([null, 80, null, 79], null).map((v) => r3(v)), [80, 80, 80, 79.9]);
  assert.deepEqual(weightTrend([null, null], null), [null, null]);
});

test("month change is 1 decimal, half away from zero", () => {
  assert.equal(monthChange(76.4, 77.06), -0.7);
  assert.equal(monthChange(76.4, 77.0), -0.6);
  assert.equal(monthChange(76.4, null), null);
});

const cases = [
  { name: "prev 2300, goal 74.0", input: { intakes: INTAKES, weights: WEIGHTS, seed: 76.9, prev: 2300, goal: 74.0 },
    want: { kcal: 2150, mode: "adaptive", tdee: 2488, intake_mean: 2276, slope_kg_day: -0.0276, rate_kg_week: -0.382, raw: 2069, intake_days: 18, weigh_ins: 15, reason: null } },
  { name: "prev 2300, goal 76.0", input: { intakes: INTAKES, weights: WEIGHTS, seed: 76.9, prev: 2300, goal: 76.0 },
    want: { kcal: 2450, rate_kg_week: 0, raw: 2488 } },
  { name: "only the first 10 intake values",
    input: { intakes: INTAKES.map((v, i) => (i < 10 ? v : null)), weights: WEIGHTS, seed: 76.9, prev: 2300, goal: 74.0 },
    want: { kcal: 2300, mode: "kept", reason: "not_enough_data", intake_days: 8, tdee: null } },
];
for (const c of cases) test(`adaptive kcal: ${c.name}`, () => {
  const got = adaptiveKcal(c.input);
  for (const [k, v] of Object.entries(c.want)) assert.equal(got[k], v, k);
});

test("adaptive kcal: too few weigh-ins keeps, floor 1400, no goal is rate 0", () => {
  const few = WEIGHTS.map((v, i) => (i < 9 ? v : null)); // 6 weigh-ins
  assert.equal(adaptiveKcal({ intakes: INTAKES, weights: few, seed: 76.9, prev: 2300, goal: 74 }).mode, "kept");
  const low = adaptiveKcal({ intakes: INTAKES.map((v) => (v === null ? null : 1100)), weights: WEIGHTS, seed: 76.9, prev: 1450, goal: 60 });
  assert.equal(low.kcal, 1400);
  assert.equal(adaptiveKcal({ intakes: INTAKES, weights: WEIGHTS, seed: 76.9, prev: 2300, goal: null }).rate_kg_week, 0);
});

test("initial target for trend 76.4 kg: 2300 kcal, 155 g protein; defaults without weight", () => {
  assert.equal(initialKcal(76.4), 2300);
  assert.equal(proteinTarget(76.4), 155);
  assert.equal(initialKcal(null), 2200);
  assert.equal(initialKcal(91.9, goalRate(80, 91.9)), 2250, "the owner's case: lose 0.46 kg/week from day one");
  assert.equal(initialKcal(50, -0.75), 1400, "floor");
  assert.equal(initialKcal(91.9, goalRate(80, 91.9), 2538), 2050, "measured Watch burn replaces 30 kcal per kg");
  const days = (n, v) => new Map(Array.from({ length: n }, (_, i) => [`2026-10-${String(i + 1).padStart(2, "0")}`, v]));
  assert.equal(measuredBurn(days(14, 2100), days(14, 400)), 2500);
  assert.equal(measuredBurn(days(13, 2100), days(13, 400)), null, "under 14 days");
  assert.equal(proteinTarget(null), 140);
});

test("steps target: median of 28 days rounded to 500, 8000 under 7 days", () => {
  assert.equal(stepsTarget([8600, 8400, 8800, 8700, 8500, 8650, 8550]), 8500); // median 8600 → 8500
  assert.equal(stepsTarget([8750, 8750, 8750, 8750, 8750, 8750, 8750]), 9000); // half away from zero
  assert.equal(stepsTarget([1, 2, 3, 4, 5, 6]), 8000);
  assert.equal(stepsTarget([]), 8000);
});

test("round helpers", () => {
  assert.deepEqual([round5(152.8), round10(2145), round50(2292), round500(8249), round500(8250)], [155, 2150, 2300, 8000, 8500]);
});

test("goalRate: explicit goal sets direction, goal weight stops it, deadband and overshoot give 0", () => {
  assert.equal(goalRate(80, 91.9), -0.4595);
  assert.equal(goalRate(null, 91.9, "lose"), -0.4595);
  assert.equal(goalRate(80, 91.9, "maintain"), 0);
  assert.equal(goalRate(80, 80.4, "lose"), 0, "within 0.5 kg");
  assert.equal(goalRate(85, 80, "lose"), 0, "already below the goal weight");
  assert.equal(goalRate(null, 70, "gain").toFixed(3), "0.175");
  assert.equal(goalRate(90, 70).toFixed(3), "0.175");
  assert.equal(goalRate(null, 70), 0);
});
