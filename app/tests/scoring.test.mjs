import { test } from "node:test";
import assert from "node:assert/strict";
import {
  bedHours, consistencyScore, digestHeadline, durationScore, efficiencyScore, hrvPart, quantile, recoveryScore, rhrPart,
  robustSpreadOf, sleepNeed, sleepParts, sleepScore, tonight, verdict, verdictCall, wakeupsScore,
} from "../dist/src/scoring.js";
import { roundHalfAway } from "../dist/src/scoring-config.js";

// §10.3 fixture: 28 nights cycling the 7 values.
const cycle = (vals, n = 28) => Array.from({ length: n }, (_, i) => vals[i % vals.length]);
const HRV_HIST = cycle([48, 52, 55, 58, 61, 55, 53]);
const RHR_HIST = cycle([54, 55, 56, 55, 54, 56, 55]);

test("roundHalfAway rounds .5 away from zero", () => {
  assert.equal(roundHalfAway(2.5), 3);
  assert.equal(roundHalfAway(-2.5), -3);
  assert.equal(roundHalfAway(-2.0067, 2), -2.01);
  assert.equal(roundHalfAway(1.2, 2), 1.2);
});

test("§10.1 duration", () => {
  for (const [a, n, want] of [[8, 8, 100], [7.5, 8, 84], [6, 8, 38], [4.8, 8, 0], [9.5, 8, 100], [7, 7.5, 83]])
    assert.equal(durationScore(a, n), want, `${a}/${n}`);
});

test("§10.1 consistency (early and late score the same)", () => {
  for (const [d, want] of [[0, 100], [10, 92], [18, 85], [45, 63], [60, 50], [120, 0], [150, 0]]) {
    assert.equal(consistencyScore(d), want, `d=${d}`);
    assert.equal(consistencyScore(-d), want, `d=-${d}`);
  }
});

test("§10.1 efficiency", () => {
  for (const [a, b, want] of [[7.6, 8, 100], [7, 8, 75], [6.5, 8, 54], [5, 8, 0], [8, 7.9, 100]])
    assert.equal(efficiencyScore(a, b), want, `${a}/${b}`);
});

test("§10.1 wakeups", () => {
  for (const [n, m, want] of [[0, 0, 100], [1, 5, 96], [2, 25, 70], [4, 40, 38], [null, 30, 76], [3, null, 80], [null, null, null], [8, 90, 0]])
    assert.equal(wakeupsScore(n, m), want, `${n},${m}`);
});

test("§10.2 sleep total and band", () => {
  const parts = (d, c, e, w) => [["duration", d], ["consistency", c], ["efficiency", e], ["wakeups", w]].map(([key, score]) => ({ key, score }));
  for (const [p, score, band] of [
    [[90, 85, 97, 70], 86, "good"], [[90, null, 97, 70], 87, "good"], [[90, null, null, null], 90, "good"],
    [[null, 85, 97, 70], null, null], [[50, 40, 80, 60], 56, "low"], [[80, 70, 70, 70], 74, "ok"],
  ]) {
    const r = sleepScore(parts(...p));
    assert.equal(r.score, score, p.join());
    assert.equal(r.band, band, p.join());
    assert.equal(r.label, band && band.toUpperCase());
  }
});

test("§3.1 sleep need", () => {
  assert.deepEqual(sleepNeed({ target: 7.5, asleepHistory: [] }), { need_h: 7.5, basis: "target" });
  assert.deepEqual(sleepNeed({ target: null, asleepHistory: cycle([7], 13) }), { need_h: 8, basis: "default" });
  // p90 of 14 nights 6.0..7.3 step 0.1 = 7.17 → 7.25
  assert.deepEqual(sleepNeed({ target: null, asleepHistory: Array.from({ length: 14 }, (_, i) => 6 + i / 10) }), { need_h: 7.25, basis: "history" });
  assert.equal(sleepNeed({ target: null, asleepHistory: cycle([5.5, 6, 6.2], 20) }).need_h, 7);
  assert.equal(sleepNeed({ target: null, asleepHistory: cycle([9.5, 10], 20) }).need_h, 9);
});

test("§3.2 bed hours uses in-bed only when it covers the sleep", () => {
  const n = { asleep_h: 7.5, in_bed_start: "2026-10-23T22:55:00+05:30", in_bed_end: "2026-10-24T07:05:00+05:30",
    sleep_start: "2026-10-23T23:02:00+05:30", sleep_end: "2026-10-24T06:51:00+05:30" };
  assert.ok(Math.abs(bedHours(n) - (8 + 10 / 60)) < 1e-9);
  assert.ok(Math.abs(bedHours({ ...n, asleep_h: 8.5 }) - (7 + 49 / 60)) < 1e-9);
  assert.ok(Math.abs(bedHours({ ...n, in_bed_start: null }) - (7 + 49 / 60)) < 1e-9);
  assert.equal(bedHours({ ...n, in_bed_start: null, sleep_end: null }), null);
});

const WORKED = { asleep_h: 7.683, need_h: 8, bedtime_min: 318, bedtimeHistory: cycle([300], 14), bed_h: 8.167, wakeups: 2, awake_min: 25 };

test("§3.4 worked example: 86 · good with API detail strings", () => {
  const parts = sleepParts(WORKED);
  assert.deepEqual(parts.map(p => [p.key, p.label, p.score, p.detail, p.flagged, p.weight]), [
    ["duration", "DURATION", 90, "OF YOUR 8H NEED", false, 0.4],
    ["consistency", "BEDTIME", 85, "18 MIN LATE", false, 0.2],
    ["efficiency", "EFFICIENCY", 97, "94% ASLEEP", false, 0.2],
    ["wakeups", "WAKE-UPS", 70, "2 · 25 MIN", false, 0.2],
  ]);
  assert.equal(parts[1].delta_min, 18);
  assert.deepEqual(sleepScore(parts), { score: 86, band: "good", label: "GOOD" });
});

test("sleep part details for early, on time, missing and flagged parts", () => {
  const p = (over) => Object.fromEntries(sleepParts({ ...WORKED, ...over }).map(x => [x.key, x]));
  assert.equal(p({ bedtime_min: 288 }).consistency.detail, "12 MIN EARLY");
  assert.equal(p({ bedtime_min: 288 }).consistency.delta_min, -12);
  assert.equal(p({ bedtime_min: 304 }).consistency.detail, "ON TIME");
  assert.deepEqual([p({ bedtimeHistory: cycle([300], 13) }).consistency.score, p({ bedtimeHistory: cycle([300], 13) }).consistency.detail], [null, "NEEDS 14 NIGHTS"]);
  assert.equal(p({ bedtime_min: null }).consistency.score, null);
  assert.deepEqual([p({ bed_h: null }).efficiency.score, p({ bed_h: null }).efficiency.detail], [null, "NO IN-BED TIME"]);
  assert.equal(p({ wakeups: null }).wakeups.detail, "25 MIN AWAKE");
  assert.equal(p({ awake_min: null, wakeups: 3 }).wakeups.detail, "3 WAKE-UPS");
  assert.equal(p({ wakeups: 4, awake_min: 40 }).wakeups.flagged, true);
  assert.equal(p({ need_h: 7.75 }).duration.detail, "OF YOUR 7H45 NEED");
});

test("§10.3 fixture baseline: medians, ranges and floored spreads", () => {
  const h = hrvPart(55, HRV_HIST), r = rhrPart(55, RHR_HIST);
  assert.equal(h.usual, 55); assert.deepEqual(h.usual_range, [48, 61]);
  assert.equal(r.usual, 55); assert.deepEqual(r.usual_range, [54, 56]);
  assert.equal(robustSpreadOf(HRV_HIST.map(Math.log), 0.1), 0.1);
  assert.equal(robustSpreadOf(RHR_HIST, 2), 2);
  assert.equal(quantile([...HRV_HIST].sort((a, b) => a - b), 0.5), 55);
});

test("§10.3 recovery parts", () => {
  for (const [fn, v, z, score] of [
    [hrvPart, 62, 1.2, 93], [hrvPart, 55, 0, 75], [hrvPart, 45, -2.01, 45], [hrvPart, 36, -4.24, 11], [hrvPart, 80, 3.75, 100],
    [rhrPart, 57, -1, 60], [rhrPart, 55, 0, 75], [rhrPart, 52, 1.5, 98], [rhrPart, 60, -2.5, 38], [rhrPart, 73, -9, 0],
  ]) {
    const p = fn(v, fn === hrvPart ? HRV_HIST : RHR_HIST);
    assert.equal(p.status, "ok");
    assert.equal(p.z, z, `${fn.name} ${v} z`);
    assert.equal(p.score, score, `${fn.name} ${v} score`);
  }
});

test("§10.3 HRV with only 13 history nights is calibrating, needs 1 more", () => {
  const p = hrvPart(62, HRV_HIST.slice(0, 13));
  assert.deepEqual([p.score, p.z, p.status, p.nights_needed], [null, null, "calibrating", 1]);
  assert.notEqual(p.usual_range, null);
  assert.equal(hrvPart(62, HRV_HIST.slice(0, 6)).usual_range, null);
  assert.equal(hrvPart(null, HRV_HIST).status, "missing");
});

test("§4 display hints: arrow follows the value, tint the better direction", () => {
  assert.deepEqual([hrvPart(62, HRV_HIST).arrow, hrvPart(62, HRV_HIST).tint], ["up", "good"]);
  assert.deepEqual([rhrPart(57, RHR_HIST).arrow, rhrPart(57, RHR_HIST).tint], ["up", "watch"]);
  assert.deepEqual([rhrPart(52, RHR_HIST).arrow, rhrPart(52, RHR_HIST).tint], ["down", "good"]);
  assert.deepEqual([hrvPart(55, HRV_HIST).arrow, hrvPart(55, HRV_HIST).tint], [null, null]);
});

const rec = (sleep, hrv, rhr) => recoveryScore({
  sleep, hrv: hrv === null ? null : hrvPart(hrv, HRV_HIST), rhr: rhr === null ? null : rhrPart(rhr, RHR_HIST),
});

test("§10.4 recovery total, band and guard", () => {
  for (const [s, h, r, score, band, guard] of [
    [86, 62, 57, 82, "ready", false], [86, 55, 55, 79, "ready", false], [60, 45, 60, 49, "ease", false],
    [30, 36, 73, 15, "rest", false], [null, 62, 57, 80, "ready", false], [86, null, 57, 75, "ready", false],
    [86, null, null, null, null, false], [98, 47, 58, 68, "ease", true], [100, 46, 58, 67, "ease", true], [95, 40, 61, 52, "ease", false],
  ]) {
    const x = rec(s, h, r);
    assert.equal(x.score, score, `${s},${h},${r} score`);
    assert.equal(x.band, band, `${s},${h},${r} band`);
    assert.equal(x.guard_applied, guard, `${s},${h},${r} guard`);
  }
  assert.equal(hrvPart(47, HRV_HIST).z, -1.57);
  assert.equal(rhrPart(58, RHR_HIST).z, -1.5);
  assert.equal(rec(86, null, null).status, "missing");
});

test("§4.1 worked example: sleep 86 + HRV 62 + RHR 57 → 82 · ready", () => {
  const sleep = sleepScore(sleepParts(WORKED)).score;
  assert.deepEqual(rec(sleep, 62, 57), { score: 82, band: "ready", label: "READY", status: "ok", reason: null, nights_needed: 0, guard_applied: false });
});

test("§4 min-parts rule: calibrating beats missing", () => {
  const short = recoveryScore({ sleep: 86, hrv: hrvPart(62, HRV_HIST.slice(0, 5)), rhr: rhrPart(57, RHR_HIST.slice(0, 5)) });
  assert.deepEqual([short.score, short.status, short.nights_needed, short.reason], [null, "calibrating", 9, "Needs 9 more nights"]);
  const noNight = recoveryScore({ sleep: null, hrv: hrvPart(62, HRV_HIST), rhr: rhrPart(null, RHR_HIST) });
  assert.deepEqual([noNight.score, noNight.status, noNight.reason], [null, "missing", "No sleep recorded for last night"]);
  const noHeart = recoveryScore({ sleep: 86, hrv: hrvPart(null, HRV_HIST), rhr: rhrPart(null, RHR_HIST) });
  assert.deepEqual([noHeart.status, noHeart.reason], ["missing", "No heart data for last night"]);
});

test("§10.8 sleep stages are not inputs: changing them leaves sleep and recovery unchanged", () => {
  const base = sleepParts(WORKED);
  for (const stages of [{ core_h: 4.1, deep_h: 1.2, rem_h: 1.9 }, { core_h: 0, deep_h: 0, rem_h: 0 }, { core_h: 7, deep_h: 3, rem_h: 0.1 }]) {
    const parts = sleepParts({ ...WORKED, ...stages });
    assert.deepEqual(parts, base);
    assert.deepEqual(sleepScore(parts), sleepScore(base));
    assert.deepEqual(recoveryScore({ sleep: sleepScore(parts).score, hrv: hrvPart(62, HRV_HIST), rhr: rhrPart(57, RHR_HIST), ...stages }),
      recoveryScore({ sleep: sleepScore(base).score, hrv: hrvPart(62, HRV_HIST), rhr: rhrPart(57, RHR_HIST) }));
  }
});

const LEGS = { template: "legs", name: "Legs" };
const V = { recovery: { band: "ready", score: 82 }, hints: { hrv: { arrow: "up", tint: "good" }, resting_hr: { arrow: "up", tint: "watch" } },
  due: LEGS, strength_today: null, kcal_left: 1780, next_slot: "lunch", now_min: 9 * 60 + 41, bed_by_min: 23 * 60 };

test("§5 verdict rules 1–9", () => {
  const cases = [
    [{ now_min: 21 * 60 + 30 }, 1, "Bed by 23:00", { kind: "bed_reminder", label: "Remind me" }],
    [{ now_min: 60 }, 1, "Bed by 23:00", { kind: "bed_reminder", label: "Remind me" }],
    [{ now_min: 22 * 60, bed_by_min: 30 }, 0, null, null],
    [{ strength_today: { title: "Push", sets: 18 }, next_slot: "dinner" }, 2, "Done for today", { kind: "log_meal", label: "Log dinner", slot: "dinner" }],
    [{ strength_today: { title: "Push", sets: 18 }, kcal_left: 300 }, 2, "Done for today", { kind: "bed_reminder", label: "Remind me" }],
    [{ recovery: { band: null, score: null, reason: "Needs 9 more nights" } }, 3, "Legs is due", { kind: "start_workout", label: "Start legs on Watch", template: "legs", intensity: "normal" }],
    [{ recovery: { band: null, score: null }, due: null }, 4, "No score yet", { kind: "log_meal", label: "Log lunch", slot: "lunch" }],
    [{}, 5, "Train legs hard today", { kind: "start_workout", label: "Start legs on Watch", template: "legs", intensity: "normal" }],
    [{ recovery: { band: "steady", score: 70 } }, 6, "Train legs as planned", { kind: "start_workout", label: "Start legs on Watch", template: "legs", intensity: "normal" }],
    [{ recovery: { band: "ease", score: 50 } }, 7, "Go easy on legs", { kind: "start_workout", label: "Start legs light", template: "legs", intensity: "light" }],
    [{ due: null }, 8, "Muscles still loaded", { kind: "log_meal", label: "Log lunch", slot: "lunch" }],
    [{ recovery: { band: "rest", score: 30 } }, 9, "Rest today", { kind: "log_meal", label: "Log lunch", slot: "lunch" }],
    [{ recovery: { band: "rest", score: 30 }, kcal_left: -120 }, 9, "Rest today", { kind: "bed_reminder", label: "Remind me" }],
  ];
  for (const [over, rule, headline, action] of cases) {
    const v = verdict({ ...V, ...over });
    if (rule === 0) { assert.notEqual(v.rule, 1, "00:30 bed_by: 22:00 is before the 23:00 window"); continue; }
    assert.equal(v.rule, rule, `${JSON.stringify(over)} rule`);
    assert.equal(v.headline, headline);
    assert.deepEqual(v.action, action);
  }
  const ready = verdict(V);
  assert.deepEqual([ready.band, ready.label, ready.reason], ["ready", "READY", "Recovery 82: HRV above your usual, resting heart rate up."]);
  assert.match(verdict({ ...V, recovery: { band: "ease", score: 50 } }).reason, /No records today\.$/);
  assert.equal(verdict({ ...V, recovery: { band: null, score: null, reason: "Needs 9 more nights" } }).reason, "Needs 9 more nights");
});

test("§5 legacy verdict call enum", () => {
  for (const [band, call] of [["ready", "good"], ["steady", "normal"], ["ease", "as_planned_no_records"], ["rest", "easy"], [null, "unknown"]])
    assert.equal(verdictCall(band), call);
});

test("§5.1 digest headline", () => {
  for (const [s, r, want] of [
    ["good", "ready", ["You slept well.", "Ready to push."]], ["ok", "steady", ["You slept okay.", "Steady day."]],
    ["low", "ease", ["Short night.", "Take it easy."]], [null, "rest", ["Morning.", "Rest today."]],
    [null, null, ["Morning.", "Let's see how today goes."]],
  ]) assert.deepEqual(digestHeadline(s, r), want);
});

test("§9.2 tonight", () => {
  assert.deepEqual(tonight({ wakeTarget: "07:00", wakeHistoryMin: [], need_h: 8 }),
    { wake_time: "07:00", bed_by: "23:00", bed_by_min: 1380, need_h: 8, label: "8H BEFORE YOUR 07:00 WAKE", wake_basis: "target" });
  const hist = tonight({ wakeTarget: null, wakeHistoryMin: [411, 405, 420, 398, 415, 409, 412], need_h: 7.75 });
  assert.deepEqual([hist.wake_time, hist.bed_by, hist.label, hist.wake_basis], ["06:50", "23:05", "7H45 BEFORE YOUR 06:50 WAKE", "history"]);
  const def = tonight({ wakeTarget: null, wakeHistoryMin: [400, 410], need_h: 8 });
  assert.deepEqual([def.wake_time, def.bed_by, def.wake_basis], ["07:00", "23:00", "default"]);
  assert.equal(tonight({ wakeTarget: "00:30", wakeHistoryMin: [], need_h: 8 }).bed_by, "16:30");
  assert.throws(() => tonight({ wakeTarget: "7am", wakeHistoryMin: [], need_h: 8 }), RangeError);
});
