import { test } from "node:test";
import assert from "node:assert/strict";
import { addDays, body, ingest, payload } from "./_env.mjs";
const { baseline, compare } = await import("../dist/src/stats.js");

const DAY = "2026-08-31";
// 30 days of resting HR 51..80 (one each), then bedtimes either side of midnight.
ingest(body(payload(addDays(DAY, -30), 30, (i) => ({ rhr: 51 + i, bed: ["22:58", "02:33", "03:12", "02:51"][i % 4] }))), { origin: "test" });

test("baseline is the median of the 30 days before, with a 10th–90th percentile range", () => {
  const b = baseline("resting_hr", DAY);
  assert.equal(b.days, 30);
  assert.equal(b.usual, 66);
  assert.equal(b.low, 54);
  assert.equal(b.high, 77);
  const c = compare("resting_hr", DAY, 79);
  assert.equal(c.flag, "high");
  assert.equal(c.reading, "worse");
  assert.equal(compare("resting_hr", DAY, 60).flag, undefined);
});

test("bedtimes either side of midnight average to a real clock time", () => {
  // 8 × 22:58, 8 × 02:33, 7 × 02:51, 7 × 03:12: the median is 02:33, not a clock-face average of 13:xx.
  assert.equal(baseline("bedtime", DAY).usual, "02:33");
});

test("under 7 days of history gives no baseline and says why", () => {
  const b = baseline("resting_hr", addDays(DAY, -27));
  assert.equal(b.usual, null);
  assert.match(b.reason, /only 3 of the 7 days/);
});
