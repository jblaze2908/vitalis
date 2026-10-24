// Body tab and manual weigh-ins (spec 10 §5, 12 §2.3). A manual entry is projected into metric_days as source
// 'Vitalis manual' in the same transaction, so every reader (scores, MCP, trend) sees one weight per day via pickPerDay.
import { z } from "zod";
import { now } from "./config.js";
import { all, one, run, tx } from "./db.js";
import { markDirty, weightSeries } from "./derived.js";
import { monthChange } from "./fuel.js";
import { freshnessBlock } from "./health.js";
import { ApiError } from "./http.js";
import { roundHalfAway } from "./scoring-config.js";
import { compare, daily } from "./stats.js";
import { effectiveTargets } from "./targets.js";
import { addDays, isoAt, localDay, parseStamp, today } from "./time.js";

export const MANUAL_SOURCE = "Vitalis manual";
const r1 = (v: number | null) => (v === null ? null : roundHalfAway(v, 1));
const r2 = (v: number | null) => (v === null ? null : roundHalfAway(v, 2));

/** The latest picked weight on or before `day`, with where it came from. */
function latest(day: string) {
  const rows = all<{ day: string; source: string; qty: number }>(`SELECT day,source,qty FROM metric_days WHERE metric='weight_kg' AND qty IS NOT NULL
    AND day=(SELECT MAX(day) FROM metric_days WHERE metric='weight_kg' AND qty IS NOT NULL AND day<=?)`, day);
  if (!rows.length) return null;
  const d = rows[0].day, kg = daily("weight_kg", d, d).get(d)!;
  const picked = rows.find((r) => r.qty === kg) ?? rows[0];
  const manual = one<{ measured_at: number; tz_offset_min: number }>(
    "SELECT measured_at,tz_offset_min FROM weight_entries WHERE day=? AND deleted_at IS NULL AND kg=? ORDER BY measured_at DESC LIMIT 1", d, kg);
  const sample = manual ? null : one<{ start_ms: number; start_offset: number | null }>(`SELECT s.start_ms, s.start_offset FROM hk_samples s JOIN hk_types t ON t.id=s.type_id
    WHERE t.metric='weight_kg' AND s.day=? AND s.deleted_at IS NULL ORDER BY s.start_ms DESC LIMIT 1`, d);
  const at = manual ? isoAt(manual.measured_at, manual.tz_offset_min) : sample ? isoAt(sample.start_ms, sample.start_offset ?? 0) : null;
  const source = manual || picked.source === MANUAL_SOURCE ? "VITALIS" : (picked.source.trim().split(/\s+/)[0] || "HEALTH").toUpperCase();
  return { kg: r1(kg), at, source, manual: !!manual || picked.source === MANUAL_SOURCE };
}

/** The Body weight block for `day`: 30-day series with the EWMA trend, change over a month, goal direction. */
export function weightBlock(day: string, at = Date.now()) {
  const series = weightSeries(addDays(day, -29), day);
  const trend = series.at(-1)?.trend_kg ?? null, monthAgo = weightSeries(addDays(day, -30), addDays(day, -30))[0]?.trend_kg ?? null;
  const change = monthChange(trend, monthAgo), goal = effectiveTargets(at).goal_weight_kg;
  return {
    trend_kg: r1(trend), month_change_kg: change, goal_kg: goal,
    toward_goal: goal === null || trend === null || change === null ? null : change === 0 ? false : (goal < trend) === (change < 0),
    latest: latest(day),
    series: series.map((p) => ({ day: p.day, raw_kg: r1(p.raw_kg), trend_kg: r2(p.trend_kg) })),
  };
}

const VITALS = [
  { key: "hrv", label: "HRV", unit: "ms" }, { key: "resting_hr", label: "RESTING HR", unit: "bpm" },
  { key: "spo2", label: "SPO2", unit: "%" }, { key: "respiratory_rate", label: "BREATHING", unit: "/min" },
] as const;

export function bodyDay(day: string, at = Date.now()) {
  const t = effectiveTargets(at), v = (key: string, d = day) => daily(key, d, d).get(d) ?? null;
  const steps = daily("steps", addDays(day, -6), day);
  return {
    day,
    weight: weightBlock(day, at),
    activity: { steps: rnd(v("steps")), steps_target: t.steps, active_kcal: rnd(v("active_kcal")), exercise_min: rnd(v("exercise_min")),
      exercise_target_min: t.exercise_min, week: Array.from({ length: 7 }, (_, i) => addDays(day, i - 6)).map((d) => ({ day: d, steps: rnd(steps.get(d) ?? null) })) },
    vitals: VITALS.map(({ key, label, unit }) => {
      // Just after midnight the new day has no reading yet: show the latest from the 2 days before, compared on its own day.
      const at = [day, addDays(day, -1), addDays(day, -2)].find((d) => v(key, d) !== null);
      const value = at ? v(key, at) : null;
      if (value === null) return { key, label, value: null, unit, usual: null, usual_range: null, flag: null, reading: null };
      const c = compare(key, at!, value);
      return { key, label, value: c.value, unit, usual: c.usual, usual_range: c.usual_range ?? null, flag: c.flag ?? null, reading: c.reading ?? null };
    }),
    freshness: freshnessBlock(at),
  };
}
const rnd = (x: number | null) => (x === null ? null : Math.round(x));

export const weightSchema = z.strictObject({
  id: z.string().min(1).max(64), kg: z.number().gt(0).lt(500),
  measured_at: z.string().min(10).max(40), hk_uuid: z.string().min(1).max(64).nullable().optional(),
});

/** Re-derive the manual metric_days row for `day` from its live entries (latest wins), or remove it. */
function project(day: string) {
  const last = one<{ kg: number }>("SELECT kg FROM weight_entries WHERE day=? AND deleted_at IS NULL ORDER BY measured_at DESC, created_at DESC LIMIT 1", day);
  if (!last) { run("DELETE FROM metric_days WHERE metric='weight_kg' AND day=? AND source=?", day, MANUAL_SOURCE); return; }
  run(`INSERT INTO metric_days(metric,day,source,qty,unit,payload_id,updated_at) VALUES('weight_kg',?,?,?,'kg',NULL,?)
    ON CONFLICT(metric,day,source) DO UPDATE SET qty=excluded.qty,updated_at=excluded.updated_at`, day, MANUAL_SOURCE, last.kg, now());
}

type Entry = { id: string; kg: number; measured_at: number; tz_offset_min: number; day: string; hk_uuid: string | null; deleted_at: number | null };

/** Idempotent by id: same body → unchanged; changed body → update (a deleted entry is revived only by a changed body). */
export function postWeight(input: z.infer<typeof weightSchema>) {
  const t = parseStamp(input.measured_at);
  if (!t) throw new ApiError(422, "measured_at: must be an ISO 8601 time with offset", "invalid");
  if (t.ms > now() + 10 * 60_000) throw new ApiError(422, "measured_at: is in the future", "invalid");
  const day = localDay(t.ms, t.offsetMin), hk = input.hk_uuid ?? null;
  return tx(() => {
    const old = one<Entry>("SELECT * FROM weight_entries WHERE id=?", input.id);
    const same = old && old.kg === input.kg && old.measured_at === t.ms && old.hk_uuid === hk;
    if (!same) {
      run(`INSERT INTO weight_entries(id,measured_at,tz_offset_min,day,kg,hk_uuid,created_at) VALUES(?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET measured_at=excluded.measured_at,tz_offset_min=excluded.tz_offset_min,day=excluded.day,kg=excluded.kg,
        hk_uuid=excluded.hk_uuid,deleted_at=NULL`, input.id, t.ms, t.offsetMin, day, input.kg, hk, now());
      project(day);
      if (old && old.day !== day) project(old.day);
      markDirty(old && old.day !== day ? [day, old.day] : [day]);
    }
    return { id: input.id, kg: input.kg, day, changed: !same };
  });
}

export function deleteWeight(id: string) {
  return tx(() => {
    const e = one<Entry>("SELECT * FROM weight_entries WHERE id=?", id);
    if (!e) throw new ApiError(404, `No weight entry ${id}`);
    if (e.deleted_at === null) {
      run("UPDATE weight_entries SET deleted_at=? WHERE id=?", now(), id);
      project(e.day);
      markDirty([e.day]);
    }
    return e.day;
  });
}

export const weightNow = (at = Date.now()) => weightBlock(today(at), at);
