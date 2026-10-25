import { test } from "node:test";
import assert from "node:assert/strict";
import { sleepBlocks } from "../dist/src/sleep-split.js";

// Wall-clock samples at +05:30. stage: 0 inBed, 1 unspecified, 2 awake, 3 core, 4 deep, 5 REM.
let n = 0;
const iso = (day, hm) => `${day}T${hm}:00.000+05:30`;
const s = (stage, day, from, to, toDay = day) => {
  const startIso = iso(day, from), endIso = iso(toDay, to);
  return { uuid: `u${n++}`, start: Date.parse(startIso), end: Date.parse(endIso), startIso, endIso, tz: null, value: stage };
};
const view = (samples) => sleepBlocks(samples).map((b) => ({ day: b.day, kind: b.kind, from: b.startIso.slice(11, 16), to: b.endIso.slice(11, 16),
  h: Math.round(b.asleep_h * 100) / 100 }));
const nights = (bs) => bs.filter((b) => b.kind === "night"), napsOf = (bs) => bs.filter((b) => b.kind === "nap");

test("a normal night is one night on the day you wake", () => {
  assert.deepEqual(view([s(3, "2026-10-26", "01:00", "08:00")]), [{ day: "2026-10-26", kind: "night", from: "01:00", to: "08:00", h: 7 }]);
});

test("today (real): 01:41–08:29 night and a 15:30 nap stay apart", () => {
  const b = view([s(3, "2026-10-25", "01:41", "08:29"), s(3, "2026-10-25", "15:30", "16:43")]);
  assert.deepEqual(nights(b), [{ day: "2026-10-25", kind: "night", from: "01:41", to: "08:29", h: 6.8 }]);
  assert.deepEqual(napsOf(b), [{ day: "2026-10-25", kind: "nap", from: "15:30", to: "16:43", h: 1.22 }]);
});

test("Fri 23 Oct (real): a 3 h night beats a 2 h afternoon sleep", () => {
  const b = view([s(3, "2026-10-22", "23:43", "03:01", "2026-10-23"), s(3, "2026-10-23", "16:17", "18:15")]);
  assert.deepEqual(nights(b).map((x) => [x.day, x.from, x.to]), [["2026-10-23", "23:43", "03:01"]]);
  assert.deepEqual(napsOf(b).map((x) => [x.day, x.from, x.to]), [["2026-10-23", "16:17", "18:15"]]);
});

test("all-nighter, asleep 07:00–13:00: that is the night", () => {
  assert.deepEqual(view([s(3, "2026-10-26", "07:00", "13:00")]), [{ day: "2026-10-26", kind: "night", from: "07:00", to: "13:00", h: 6 }]);
});

test("all-nighter, asleep 11:00–17:00: with no night sleep, the longest block is the night", () => {
  assert.deepEqual(view([s(3, "2026-10-26", "11:00", "17:00")]).map((x) => [x.day, x.kind]), [["2026-10-26", "night"]]);
});

test("an hour awake at 03:00 stays inside one night and counts as one wake-up", () => {
  const bs = sleepBlocks([s(3, "2026-10-25", "23:00", "03:00", "2026-10-26"), s(2, "2026-10-26", "03:00", "04:00"), s(4, "2026-10-26", "04:00", "08:00")]);
  assert.equal(bs.length, 1);
  assert.deepEqual([bs[0].day, bs[0].kind, bs[0].asleep_h, bs[0].awake_h, bs[0].wakeups], ["2026-10-26", "night", 8, 1, 1]);
});

test("a gap with no awake sample still counts as a wake-up", () => {
  const [b] = sleepBlocks([s(3, "2026-10-25", "23:00", "02:00", "2026-10-26"), s(3, "2026-10-26", "02:30", "07:00")]);
  assert.deepEqual([b.asleep_h, b.wakeups], [7.5, 1]);
});

test("evening crash 20:00–23:00, then 02:00–08:00: the later block is the night, the evening one a nap of the same morning", () => {
  const b = view([s(3, "2026-10-26", "20:00", "23:00"), s(3, "2026-10-27", "02:00", "08:00")]);
  assert.deepEqual(nights(b).map((x) => [x.day, x.from, x.h]), [["2026-10-27", "02:00", 6]]);
  assert.deepEqual(napsOf(b).map((x) => [x.day, x.from, x.h]), [["2026-10-27", "20:00", 3]]);
});

test("early night 20:00–01:00 belongs to the next morning", () => {
  assert.deepEqual(view([s(3, "2026-10-26", "20:00", "01:00", "2026-10-27")]).map((x) => [x.day, x.kind, x.h]), [["2026-10-27", "night", 5]]);
});

test("sleep starting at exactly 18:00 counts toward the next morning; 17:59 stays on the same day", () => {
  assert.equal(view([s(3, "2026-10-26", "18:00", "19:00")])[0].day, "2026-10-27");
  assert.equal(view([s(3, "2026-10-26", "17:59", "19:00")])[0].day, "2026-10-26");
});

test("broken night with 3 h awake: two blocks, the longer one is the night (needs the manual switch)", () => {
  const b = view([s(3, "2026-10-26", "20:00", "01:00", "2026-10-27"), s(3, "2026-10-27", "04:00", "08:00")]);
  assert.deepEqual(b.map((x) => [x.day, x.kind, x.from]), [["2026-10-27", "night", "20:00"], ["2026-10-27", "nap", "04:00"]]);
  const c = view([s(3, "2026-10-26", "23:00", "02:00", "2026-10-27"), s(3, "2026-10-27", "05:30", "09:00")]);
  assert.deepEqual(c.map((x) => [x.kind, x.from]), [["nap", "23:00"], ["night", "05:30"]]);
});

test("short night and a long afternoon sleep: the night stays the night", () => {
  const b = view([s(3, "2026-10-26", "01:00", "05:00"), s(3, "2026-10-26", "13:00", "18:00")]);
  assert.deepEqual(b.map((x) => [x.kind, x.from, x.h]), [["night", "01:00", 4], ["nap", "13:00", 5]]);
});

test("two naps in one day are both kept; a 10-minute doze is dropped", () => {
  const b = view([s(3, "2026-10-26", "00:30", "07:30"), s(3, "2026-10-26", "13:00", "13:30"), s(3, "2026-10-26", "14:30", "14:40"), s(3, "2026-10-26", "17:00", "17:40")]);
  assert.deepEqual(b.map((x) => [x.kind, x.from]), [["night", "00:30"], ["nap", "13:00"], ["nap", "17:00"]]);
});

test("stages and in-bed edges come from the night block only", () => {
  const [night, nap] = sleepBlocks([s(0, "2026-10-25", "22:30", "08:00", "2026-10-26"), s(3, "2026-10-25", "23:00", "02:00", "2026-10-26"),
    s(4, "2026-10-26", "02:00", "03:00"), s(5, "2026-10-26", "03:00", "07:00"), s(1, "2026-10-26", "15:00", "16:00")]);
  assert.deepEqual([night.kind, night.core_h, night.deep_h, night.rem_h, night.inBedStart, night.inBedEnd],
    ["night", 3, 1, 4, "2026-10-25T22:30:00.000+05:30", "2026-10-26T08:00:00.000+05:30"]);
  assert.deepEqual([nap.kind, nap.asleep_h, nap.core_h, nap.wakeups], ["nap", 1, null, null]);
});
