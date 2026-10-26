// Heart rate over time, read from raw HealthKit samples: metric_days keeps only each day's min/avg/max.
import { all } from "./db.js";
import { freshnessBlock } from "./health.js";
import { baseline, compare, daily, nights } from "./stats.js";
import { addDays, isoAt, ownerOffsetMin, today } from "./time.js";
import { heartReadings, ownOrAll, type Reading } from "./hr-readings.js";

type Bucket = { i: number; n: number; sum: number; lo: number; hi: number };
/** Fixed-width buckets from `startMs`; empty buckets are left out so a gap in wear stays a gap. */
function buckets(rs: Reading[], startMs: number, widthMs: number) {
  const m = new Map<number, Bucket>();
  for (const r of rs) {
    const i = Math.floor((r.ms - startMs) / widthMs), b = m.get(i);
    if (b) { b.n++; b.sum += r.bpm; b.lo = Math.min(b.lo, r.bpm); b.hi = Math.max(b.hi, r.bpm); } else m.set(i, { i, n: 1, sum: r.bpm, lo: r.bpm, hi: r.bpm });
  }
  return [...m.values()].sort((a, b) => a.i - b.i);
}

/** A workout's heart rate: ≤ ~240 points (`s` = seconds from start) plus min/avg/max of the same readings. */
export function workoutHeart(startMs: number, endMs: number, source: string | null, bundle?: string | null) {
  const rs = ownOrAll(heartReadings(startMs, endMs), source, bundle);
  if (!rs.length) return null;
  const width = Math.max(5_000, Math.ceil((endMs - startMs) / 240 / 5_000) * 5_000);
  const total = rs.reduce((t, r) => t + r.bpm, 0);
  return {
    bucket_s: width / 1000,
    points: buckets(rs, startMs, width).map((b) => ({ s: (b.i * width) / 1000, bpm: Math.round(b.sum / b.n) })),
    min: Math.round(Math.min(...rs.map((r) => r.bpm))), avg: Math.round(total / rs.length), max: Math.round(Math.max(...rs.map((r) => r.bpm))),
  };
}

const BUCKET_MIN = 5;
const minuteOf = (ms: number, dayStart: number) => Math.floor((ms - dayStart) / 60_000);

/** `/v2/heart`: one local day in 5-minute buckets, with that day's sleep and workouts so the curve can be read. */
export function heartDay(day: string, at = Date.now()) {
  const off = ownerOffsetMin(at), start = Date.parse(`${day}T00:00:00Z`) - off * 60_000, end = start + 86_400_000 - 1;
  const rs = heartReadings(start, end);
  const pts = buckets(rs, start, BUCKET_MIN * 60_000).map((b) => ({ m: b.i * BUCKET_MIN, avg: Math.round(b.sum / b.n), lo: Math.round(b.lo), hi: Math.round(b.hi) }));
  const lo = rs.reduce<Reading | null>((x, r) => (!x || r.bpm < x.bpm ? r : x), null), hi = rs.reduce<Reading | null>((x, r) => (!x || r.bpm > x.bpm ? r : x), null);
  const hm = (ms: number) => isoAt(ms, off).slice(11, 16);
  const resting = daily("resting_hr", day, day).get(day) ?? null;
  // Sleep that ended this morning, and tonight's night once it exists (keyed by the next day), clipped to this day.
  const sleep = [...nights(day, addDays(day, 1))].filter((n) => n.sleep_start && n.sleep_end).map((n) => ({
    start_m: Math.max(0, minuteOf(Date.parse(n.sleep_start!), start)), end_m: Math.min(1440, minuteOf(Date.parse(n.sleep_end!), start)) }))
    .filter((s) => s.end_m > 0 && s.start_m < 1440 && s.end_m > s.start_m);
  const workouts = all<{ id: string; name: string; start_ms: number; end_ms: number; hr_avg: number | null; hr_max: number | null }>(
    "SELECT id,name,start_ms,end_ms,hr_avg,hr_max FROM hk_workouts WHERE start_ms<=? AND end_ms>=? ORDER BY start_ms", end, start)
    .map((w) => ({ id: w.id, title: w.name, start_m: Math.max(0, minuteOf(w.start_ms, start)), end_m: Math.min(1440, minuteOf(w.end_ms, start)),
      avg_bpm: w.hr_avg && Math.round(w.hr_avg), max_bpm: w.hr_max && Math.round(w.hr_max) }));
  const avg = rs.length ? Math.round(rs.reduce((t, r) => t + r.bpm, 0) / rs.length) : null;
  const usual = baseline("heart_rate", day);
  const t = today(at);
  return {
    day, prev_day: addDays(day, -1), next_day: day >= t ? null : addDays(day, 1), bucket_min: BUCKET_MIN, readings: rs.length,
    now_m: day === t ? minuteOf(at, start) : null,
    points: pts,
    summary: {
      avg, min: lo && Math.round(lo.bpm), min_at: lo && hm(lo.ms), max: hi && Math.round(hi.bpm), max_at: hi && hm(hi.ms),
      avg_usual: usual.raw ? Math.round(usual.raw.usual) : null,
      resting: resting === null ? null : compare("resting_hr", day, resting),
    },
    sleep, workouts,
    freshness: freshnessBlock(at),
  };
}
