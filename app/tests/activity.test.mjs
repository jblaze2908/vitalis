// 11 §6 and §10.7; activity.ts is pure, so no database harness.
import { test } from "node:test";
import assert from "node:assert/strict";
const { curveFromSamples, usualFractionNow, usualTotal, expectedNow, pace, paceLabel } = await import("../dist/src/activity.js");

const DAY = "2026-10-24", OFF = 330; // +05:30
const at = (hh, mm = 0) => Date.parse(`${DAY}T00:00:00Z`) - OFF * 60_000 + (hh * 60 + mm) * 60_000;
const s = (h0, m0, h1, m1, value, source = "Test Watch") => ({ start_ms: at(h0, m0), end_ms: at(h1, m1), value, source });

test("pace table (§10.7)", () => {
  const rows = [[3206, 2600, "ahead"], [3206, 3000, "on_pace"], [2000, 3000, "behind"], [150, 200, "early"], [5000, null, "unknown"]];
  for (const [today, expected, want] of rows) assert.equal(pace(today, expected, "steps"), want, `${today}, ${expected}`);
  assert.equal(pace(20, 25, "kcal"), "early");
  assert.equal(pace(212, 240, "kcal"), "behind"); // 212 ≤ 0.9 × 240 (the 10 §4 example body shows on_pace)
  assert.deepEqual(["ahead", "behind", "on_pace", "early", "unknown"].map(paceLabel), ["AHEAD", "BEHIND", "ON PACE", null, null]);
});

test("curve: monotonic, ends at 1, splits a sample across local hours by overlap", () => {
  const f = curveFromSamples([s(7, 30, 8, 30, 1000), s(12, 0, 12, 0, 1000), s(20, 0, 21, 0, 2000)], DAY, OFF);
  assert.equal(f.length, 24);
  for (let h = 1; h < 24; h++) assert.ok(f[h] >= f[h - 1]);
  assert.equal(f[23], 1);
  assert.equal(f[6], 0);
  assert.equal(f[7], 0.125);  // half of the 07:30–08:30 sample by end of hour 7
  assert.equal(f[8], 0.25);
  assert.equal(f[12], 0.5);   // zero-length sample counts in its start hour
  assert.equal(f[20], 1);
});

test("curve: largest source wins, equal totals go to the smaller name, outside-day parts dropped", () => {
  const f = curveFromSamples([s(9, 0, 10, 0, 500, "Phone"), s(18, 0, 19, 0, 800, "Watch")], DAY, OFF);
  assert.equal(f[9], 0);
  assert.equal(f[18], 1);
  const tie = curveFromSamples([s(9, 0, 10, 0, 500, "B"), s(18, 0, 19, 0, 500, "A")], DAY, OFF);
  assert.equal(tie[9], 0); // "A" picked
  // 23:00–01:00 straddles midnight: only the in-day half counts, all of it in hour 23.
  const edge = curveFromSamples([s(6, 0, 7, 0, 100), s(23, 0, 25, 0, 200)], DAY, OFF);
  assert.equal(edge[22], 0.5);
  assert.equal(curveFromSamples([], DAY, OFF), null);
  assert.equal(curveFromSamples([s(26, 0, 27, 0, 100)], DAY, OFF), null);
});

test("usual fraction now: hour interpolation and median over ≥ 7 curves", () => {
  const curve = (k) => Array.from({ length: 24 }, (_, h) => Math.min(1, (h + 1) * k));
  const curves = [0.04, 0.05, 0.06, 0.05, 0.05, 0.03, 0.07].map(curve);
  // 09:30 → halfway between f[8] and f[9] of the median curve (k 0.05): (0.45 + 0.5) / 2.
  assert.ok(Math.abs(usualFractionNow(curves, 570) - 0.475) < 1e-12);
  assert.equal(usualFractionNow(curves, 0), 0);
  assert.equal(usualFractionNow(curves, 1440), 1);
  assert.equal(usualFractionNow(curves.slice(0, 6), 570), null);
});

test("usual total and expected now", () => {
  assert.equal(usualTotal([9000, 8000, 10000, 7000, 11000, 8500, 9500]), 9000);
  assert.equal(usualTotal([1, 2, 3, 4, 5, 6]), null);
  assert.equal(expectedNow(9000, 0.2889), 2600);
  assert.equal(expectedNow(null, 0.3), null);
  assert.equal(pace(3206, expectedNow(9000, 0.2889), "steps"), "ahead");
});
