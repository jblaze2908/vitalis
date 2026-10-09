import { test } from "node:test";
import assert from "node:assert/strict";
import { all, body, http, one, payload, tokens } from "./_env.mjs";

const ingestTok = tokens.createToken("phone", "ingest").token;
const readTok = tokens.createToken("agent", "read").token;

test("push stores the raw body, then parses metrics, sleep and workouts in fixed units", async () => {
  const p = payload("2026-09-01", 2, (i) => ({ kj: 4184, rhr: 58 + i }));
  p.data.workouts.push({ id: "W-1", name: "Elliptical", start: "2026-09-02 19:52:16 +0530", end: "2026-09-02 20:02:22 +0530", duration: 606,
    activeEnergyBurned: { qty: 498.6, units: "kJ" }, activities: [{ metrics: { heartRateAverage: { qty: 165.1, units: "bpm" }, heartRateMaximum: { qty: 177 } } }] });
  const r = await http("POST", "/ingest", { token: ingestTok, raw: body(p), headers: { "automation-name": "Daily" } });
  assert.equal(r.status, 200, r.text);
  assert.deepEqual(r.json.counts, { metric_days: 14, sleep_nights: 2, workouts: 1, skipped_metrics: 0 });
  assert.equal(one("SELECT qty FROM metric_days WHERE metric='active_kcal' AND day='2026-09-01'").qty, 1000);
  assert.equal(one("SELECT qty FROM metric_days WHERE metric='resting_hr' AND day='2026-09-02'").qty, 59);
  const hr = one("SELECT min,avg,max FROM metric_days WHERE metric='heart_rate' AND day='2026-09-01'");
  assert.deepEqual({ ...hr }, { min: 50, avg: 75, max: 150 });
  // Stage hours, not the zeroed totals, make time asleep; the night belongs to the day of waking.
  const n = one("SELECT asleep_h, sleep_start FROM sleep_nights WHERE day='2026-09-02'");
  assert.equal(Math.round(n.asleep_h * 100) / 100, 7);
  assert.equal(n.sleep_start, "2026-09-01T23:30:00+05:30");
  const w = one("SELECT hr_avg, hr_max, active_kcal, day FROM hk_workouts WHERE id='W-1'");
  assert.equal(Math.round(w.active_kcal), 119);
  assert.equal(w.hr_max, 177);
  assert.equal(one("SELECT automation FROM payloads WHERE id=?", r.json.payload_id).automation, "Daily");
});

test("the same body twice is a no-op; a later value for the same day replaces the earlier one", async () => {
  const p = payload("2026-09-10", 1, () => ({ steps: 1200 }));
  const a = await http("POST", "/ingest", { token: ingestTok, raw: body(p) });
  const b = await http("POST", "/ingest", { token: ingestTok, raw: body(p) });
  assert.equal(b.json.duplicate, true);
  assert.equal(b.json.payload_id, a.json.payload_id);
  await http("POST", "/ingest", { token: ingestTok, raw: body(payload("2026-09-10", 1, () => ({ steps: 8400 }))) });
  assert.deepEqual(all("SELECT qty FROM metric_days WHERE metric='steps' AND day='2026-09-10'").map((r) => r.qty), [8400]);
});

test("hourly data and unsummarised sleep are skipped with a warning, the rest still lands", async () => {
  const p = { data: { metrics: [
    { name: "step_count", units: "count", data: [{ date: "2026-09-20 09:00:00 +0530", qty: 300 }, { date: "2026-09-20 10:00:00 +0530", qty: 500 }] },
    { name: "sleep_analysis", units: "hr", data: [{ startDate: "2026-09-19 23:00:00 +0530", endDate: "2026-09-19 23:30:00 +0530", qty: 0.5, value: "Core" }] },
    { name: "resting_heart_rate", units: "count/min", data: [{ date: "2026-09-20 00:00:00 +0530", qty: 61, source: "Test Watch" }] },
    { name: "weight_body_mass", units: "lb", data: [{ date: "2026-09-20 00:00:00 +0530", qty: 200, source: "Health" }] },
  ] } };
  const r = await http("POST", "/ingest", { token: ingestTok, raw: body(p) });
  assert.equal(r.status, 200);
  assert.ok(r.json.warnings.some((w) => /Time Grouping to Day/.test(w)), r.text);
  assert.ok(r.json.warnings.some((w) => /Summarize Data/.test(w)), r.text);
  assert.equal(one("SELECT qty FROM metric_days WHERE metric='resting_hr' AND day='2026-09-20'").qty, 61);
  assert.equal(Math.round(one("SELECT qty FROM metric_days WHERE metric='weight_kg' AND day='2026-09-20'").qty * 10) / 10, 90.7);
  assert.equal(one("SELECT COUNT(*) n FROM metric_days WHERE metric='steps' AND day='2026-09-20'").n, 0);
});

test("ingest refuses bad tokens, read tokens and non-JSON", async () => {
  assert.equal((await http("POST", "/ingest", { raw: "{}" })).status, 401);
  assert.equal((await http("POST", "/ingest", { token: readTok, raw: "{}" })).status, 401);
  const r = await http("POST", "/ingest", { token: ingestTok, raw: "not json" });
  assert.equal(r.status, 400);
  assert.match(r.json.error, /JSON/);
});

test("12-hour times with a narrow no-break space parse", async () => {
  const { parseStamp } = await import("../dist/src/time.js");
  assert.equal(parseStamp("2026-10-05 10:58:32 PM +0530").iso, "2026-10-05T22:58:32+05:30");
  assert.equal(parseStamp("2026-10-06").day, "2026-10-06");
});
