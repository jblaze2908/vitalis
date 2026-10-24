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

test("source selection prefers merged rows, largest cumulative qty, and deterministic discrete ties", async () => {
  const { run } = await import("../dist/src/db.js");
  const { daily } = await import("../dist/src/stats.js");
  const put = (metric, day, source, qty, avg) => run(`INSERT INTO metric_days(metric,day,source,qty,avg,unit,updated_at) VALUES(?,?,?,?,?,'test',0)`, metric, day, source, qty, avg);
  put("steps", "2027-02-01", "A Native Watch", 200, null);
  put("steps", "2027-02-01", "Z Merged Watch", 9000, null);
  assert.equal(daily("steps", "2027-02-01", "2027-02-01").get("2027-02-01"), 9000);
  put("steps", "2027-02-01", "", 8000, null);
  assert.equal(daily("steps", "2027-02-01", "2027-02-01").get("2027-02-01"), 8000);
  put("resting_hr", "2027-02-01", "Z Watch", null, 75);
  put("resting_hr", "2027-02-01", "A Watch", null, 60);
  put("resting_hr", "2027-02-01", "Phone", null, 90);
  assert.equal(daily("resting_hr", "2027-02-01", "2027-02-01").get("2027-02-01"), 60);
});

test("discrete HAE qty rows keep Watch ranking and deterministic ties", async () => {
  const { run } = await import('../dist/src/db.js');
  const { daily } = await import('../dist/src/stats.js');
  for (const [source, qty] of [['Z Watch', 75], ['A Watch', 60], ['Phone', 90]])
    run("INSERT INTO metric_days(metric,day,source,qty,unit,updated_at) VALUES('resting_hr','2027-02-02',?,?,'bpm',0)", source, qty);
  assert.equal(daily('resting_hr', '2027-02-02', '2027-02-02').get('2027-02-02'), 60);
});

test("robust spread is 1.4826 × MAD with a floor, and baselines span 60 days", async () => {
  const { robustSpread, BASELINE_DAYS, MIN_SCORE_DAYS } = await import("../dist/src/stats.js");
  assert.equal(robustSpread([1, 2, 3, 4, 100], 0), 1.4826);
  assert.equal(robustSpread([5, 5, 5, 5], 2), 2);
  assert.equal(robustSpread([], 0.1), 0.1);
  assert.equal(BASELINE_DAYS, 60);
  assert.equal(MIN_SCORE_DAYS, 14);
  assert.equal(baseline("resting_hr", addDays(DAY, 29)).days, 30, "a day 29 days later still sees all 30 history days");
});
