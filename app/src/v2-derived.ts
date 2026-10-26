import { BY_KEY } from "./catalog.js";
import { now } from "./config.js";
import { all, one, run } from "./db.js";
import { dayAt, HK_METRICS, HR_TYPE, nativeValue, SLEEP_TYPE, splitDays, STAND_TYPE } from "./v2-metrics.js";
import { heartReadings, ownOrAll } from "./hr-readings.js";
import { sleepBlocks, type SleepBlock } from "./sleep-split.js";
import { addDays } from "./time.js";
import type { DailyStat, Sample } from "./v2-schema.js";

export type RawRow = { id: number; type_id: number; source_id: number | null; uuid: string; type: string; kind: Sample["kind"]; start_ms: number; end_ms: number; start_iso: string; end_iso: string;
  series_start?: number | null; series_end?: number | null; tz: string | null; source_name: string; source_bundle: string; category_value: number | null; extra_json: string; content_hash: string; payload_id: number; deleted_at: number | null };
type MetricGroup = { metric: string; day: string; source: string };
type Window = { source: string; start: number; end: number };
const HOUR = 3_600_000;

// Keep the small touched groups outside the range seeks: SQLite otherwise flattens json_each into a ledger scan.
export const METRIC_AGGREGATE_SQL = `
      WITH touched AS MATERIALIZED (
        SELECT t.id type_id,json_extract(j.value,'$.metric') metric,json_extract(j.value,'$.day') day,json_extract(j.value,'$.source') source
        FROM json_each(?) j JOIN hk_types t ON t.metric=json_extract(j.value,'$.metric')
      ), pieces AS (
        SELECT g.metric,g.day,g.source,COUNT(*) n,SUM(s.native_value) total,MIN(s.native_value) min,MAX(s.native_value) max
        FROM touched g CROSS JOIN hk_sources src ON src.name=g.source
        CROSS JOIN hk_samples s INDEXED BY hk_samples_day ON s.type_id=g.type_id AND s.day=g.day AND s.source_id=src.id
        WHERE s.deleted_at IS NULL AND s.day IS NOT NULL AND s.native_value IS NOT NULL GROUP BY g.metric,g.day,g.source
        UNION ALL
        SELECT g.metric,g.day,g.source,SUM(v.n),SUM(v.total),MIN(v.min),MAX(v.max)
        FROM touched g CROSS JOIN hk_value_days v INDEXED BY hk_value_days_day ON v.day=g.day CROSS JOIN hk_samples s ON s.id=v.sample_id AND s.type_id=g.type_id
        CROSS JOIN hk_sources src ON src.id=s.source_id AND src.name=g.source WHERE s.deleted_at IS NULL GROUP BY g.metric,g.day,g.source
      ), totals AS (SELECT metric,day,source,SUM(n) n,SUM(total) total,MIN(min) min,MAX(max) max FROM pieces GROUP BY metric,day,source)
      SELECT g.metric,g.day,g.source,COALESCE(a.n,0) n,a.total sum,a.min,a.total/a.n avg,a.max FROM touched g
      LEFT JOIN totals a ON a.metric=g.metric AND a.day=g.day AND a.source=g.source`;

export class Derivations {
  private metrics = new Map<string, MetricGroup>();
  private sleepWindows: Window[] = [];
  private sleepAffected = new Map<string, { day: string; source: string }>();
  private sleepTouched = new Set<string>();
  private workouts = new Set<string>();
  private hrWindows: Window[] = [];
  readonly newNights: string[] = [];
  /** Local days whose daily values or night this batch may have changed; the caller marks them dirty. */
  readonly touchedDays = new Set<string>();
  private priorGroups = new Map<string, MetricGroup[]>();
  private priorNights = new Map<string, { day: string; source: string }>();
  constructor(private payloadId: number, uuids: string) {
    for (const r of all<MetricGroup & { uuid: string }>("SELECT DISTINCT uuid,metric,day,source FROM hk_values WHERE uuid IN (SELECT value FROM json_each(?))", uuids)) {
      const groups = this.priorGroups.get(r.uuid) ?? []; groups.push(r); this.priorGroups.set(r.uuid, groups);
    }
    for (const r of all<{ uuid: string; day: string; source: string }>("SELECT * FROM hk_sleep_members WHERE uuid IN (SELECT value FROM json_each(?))", uuids)) this.priorNights.set(r.uuid, r);
  }

  touch(row: RawRow) {
    for (const g of this.priorGroups.get(row.uuid) ?? []) this.group(g);
    if (row.type === SLEEP_TYPE) {
      this.sleepWindows.push({ source: row.source_name, start: row.start_ms, end: row.end_ms });
      this.sleepTouched.add(row.uuid);
      const old = this.priorNights.get(row.uuid);
      if (old) this.sleepAffected.set(JSON.stringify([old.day, old.source]), old);
    }
    if (row.kind === "workout") this.workouts.add(row.uuid);
    if (row.type === HR_TYPE && row.deleted_at === null) this.hrWindows.push({ source: row.source_name,
      start: Math.min(row.start_ms, row.series_start ?? row.start_ms), end: Math.max(row.end_ms, row.series_end ?? row.end_ms) });
  }
  private group(g: MetricGroup) { this.metrics.set(JSON.stringify([g.metric, g.day, g.source]), g); this.touchedDays.add(g.day); }

  project(s: Sample, id: number, projection: Projection) {
    const m = HK_METRICS.get(s.type);
    if (!m) return;
    if (projection.day !== null) this.group({ metric: m.def.key, day: projection.day, source: s.source.name });
    for (const d of projection.days) {
      run("INSERT INTO hk_value_days(sample_id,day,n,total,min,max) VALUES(?,?,?,?,?,?)", id, d.day, d.n, d.total, d.min, d.max);
      this.group({ metric: m.def.key, day: d.day, source: s.source.name });
    }
  }

  daily(s: DailyStat) {
    const m = HK_METRICS.get(s.type);
    if (!m) return;
    this.touchedDays.add(s.day);
    const cv = (v: number | null | undefined) => v == null ? null : s.type === STAND_TYPE && s.unit === "count" ? v : nativeValue(m.def.key, v, s.unit);
    const qty = m.cumulative ? cv(s.sum) : null, min = m.cumulative ? null : cv(s.min), avg = m.cumulative ? null : cv(s.avg), max = m.cumulative ? null : cv(s.max);
    if ([qty, min, avg, max].every((v) => v === null)) {
      run("DELETE FROM metric_days WHERE metric=? AND day=? AND source='' AND payload_id IN (SELECT id FROM payloads WHERE origin='v2')", m.def.key, s.day);
      return;
    }
    this.writeMetric(m.def.key, s.day, "", qty, min, avg, max);
  }

  finish() {
    const aggregates = all<MetricGroup & { n: number; sum: number; min: number; avg: number; max: number }>(METRIC_AGGREGATE_SQL, JSON.stringify([...this.metrics.values()]));
    for (const a of aggregates) {
      const { metric, day, source } = a;
      if (!a.n) {
        run("DELETE FROM metric_days WHERE metric=? AND day=? AND source=? AND payload_id IN (SELECT id FROM payloads WHERE origin='v2')", metric, day, source);
      } else {
        const cumulative = [...HK_METRICS.values()].some((m) => m.def.key === metric && m.cumulative);
        this.writeMetric(metric, day, source, cumulative ? a.sum : null, cumulative ? null : a.min, cumulative ? null : a.avg, cumulative ? null : a.max);
      }
    }
    this.sleep();
    for (const w of this.merge(this.hrWindows, 24 * HOUR)) {
      // Refresh existing workouts too when heart rate arrives in a later batch or is removed.
      for (const r of all<{ id: string }>("SELECT id FROM hk_workouts WHERE start_ms<=? AND end_ms>=?", w.end, w.start)) this.workouts.add(r.id);
    }
    for (const id of this.workouts) this.workout(id);
  }

  private writeMetric(metric: string, day: string, source: string, qty: number | null, min: number | null, avg: number | null, max: number | null) {
    run(`INSERT INTO metric_days(metric,day,source,qty,min,avg,max,unit,payload_id,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(metric,day,source) DO UPDATE SET qty=excluded.qty,min=excluded.min,avg=excluded.avg,max=excluded.max,
      unit=excluded.unit,payload_id=excluded.payload_id,updated_at=excluded.updated_at`, metric, day, source, qty, min, avg, max, BY_KEY.get(metric)!.unit, this.payloadId, now());
  }

  private merge(windows: Window[], gap = 0) {
    const out: Window[] = [];
    for (const w of windows.sort((a, b) => a.source.localeCompare(b.source) || a.start - b.start)) {
      const prev = out.at(-1);
      if (prev && prev.source === w.source && w.start <= prev.end + gap) prev.end = Math.max(prev.end, w.end);
      else out.push({ ...w });
    }
    return out;
  }

  /** Recompute every night and nap of the sources whose sleep changed in this batch (or in resplitAll). */
  private sleep() {
    const bySource = new Map<string, { start: number; end: number; days: Set<string> }>();
    const span = (source: string) => bySource.get(source) ?? bySource.set(source, { start: Infinity, end: -Infinity, days: new Set() }).get(source)!;
    for (const w of this.sleepWindows) { const s = span(w.source); s.start = Math.min(s.start, w.start); s.end = Math.max(s.end, w.end); }
    for (const { day, source } of this.sleepAffected.values()) {
      const s = span(source); s.days.add(day);
      // Bounds include tombstoned members, so a moved or deleted segment still pulls in its old sleep day.
      for (const r of all<RawRow>("SELECT s.* FROM hk_sleep_members m JOIN hk_raw s USING(uuid) WHERE m.day=? AND m.source=?", day, source)) {
        s.start = Math.min(s.start, r.start_ms); s.end = Math.max(s.end, r.end_ms);
      }
    }
    for (const uuid of this.sleepTouched) run("DELETE FROM hk_sleep_members WHERE uuid=?", uuid);
    for (const [source, s] of bySource) {
      if (!Number.isFinite(s.start)) continue;
      const duration = one<{ duration_ms: number }>("SELECT duration_ms FROM hk_sleep_bounds WHERE source=?", source)?.duration_ms ?? 0;
      // A sleep day's blocks start within 24 h of each other, so a 48 h margin sees every block of any day touched here.
      const rows = all<RawRow>(`SELECT r.* FROM hk_samples s JOIN hk_raw r ON r.id=s.id
        WHERE s.kind=1 AND s.deleted_at IS NULL AND s.type_id=(SELECT id FROM hk_types WHERE identifier=?)
        AND s.source_id IN (SELECT id FROM hk_sources WHERE name=?) AND s.start_ms BETWEEN ? AND ? AND s.end_ms>=?`,
        SLEEP_TYPE, source, s.start - 48 * HOUR - duration, s.end + 48 * HOUR, s.start - 48 * HOUR);
      const blocks = sleepBlocks(rows.map((r) => ({ uuid: r.uuid, start: r.start_ms, end: r.end_ms, startIso: r.start_iso, endIso: r.end_iso, tz: r.tz, value: r.category_value ?? -1 })));
      for (const b of blocks) if (b.end >= s.start && b.start <= s.end) s.days.add(b.day);
      for (const day of s.days) this.writeSleepDay(day, source, blocks.filter((b) => b.day === day));
    }
  }

  private writeSleepDay(day: string, source: string, blocks: SleepBlock[]) {
    // A nap changes the next night's sleep need, so that day's scores go stale too.
    this.touchedDays.add(day); this.touchedDays.add(addDays(day, 1));
    run("DELETE FROM hk_sleep_members WHERE day=? AND source=?", day, source);
    run("DELETE FROM sleep_naps WHERE day=? AND source=?", day, source);
    const night = blocks.find((b) => b.kind === "night");
    if (!night) {
      run("DELETE FROM sleep_nights WHERE day=? AND source=? AND payload_id IN (SELECT id FROM payloads WHERE origin='v2')", day, source);
      return;
    }
    for (const b of blocks) for (const uuid of b.members) run("INSERT OR REPLACE INTO hk_sleep_members(uuid,day,source) VALUES(?,?,?)", uuid, day, source);
    for (const b of blocks) if (b.kind === "nap") run("INSERT INTO sleep_naps(day,source,start,end,asleep_h,payload_id,updated_at) VALUES(?,?,?,?,?,?,?)",
      day, source, b.startIso, b.endIso, b.asleep_h, this.payloadId, now());
    if (!one("SELECT 1 FROM sleep_nights WHERE day=?", day)) this.newNights.push(day);
    run(`INSERT INTO sleep_nights(day,source,sleep_start,sleep_end,in_bed_start,in_bed_end,asleep_h,core_h,deep_h,rem_h,awake_h,wakeups,payload_id,updated_at)
      VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(day,source) DO UPDATE SET sleep_start=excluded.sleep_start,sleep_end=excluded.sleep_end,
      in_bed_start=excluded.in_bed_start,in_bed_end=excluded.in_bed_end,asleep_h=excluded.asleep_h,core_h=excluded.core_h,deep_h=excluded.deep_h,
      rem_h=excluded.rem_h,awake_h=excluded.awake_h,wakeups=excluded.wakeups,payload_id=excluded.payload_id,updated_at=excluded.updated_at`,
      day, source, night.startIso, night.endIso, night.inBedStart, night.inBedEnd, night.asleep_h,
      night.core_h, night.deep_h, night.rem_h, night.awake_h, night.wakeups, this.payloadId, now());
  }

  /** One-off: recompute every stored night with the current night/nap rules. Run once per rule change from server start. */
  resplitAll() {
    for (const r of all<{ source: string; start: number; end: number }>(`SELECT src.name source,MIN(s.start_ms) start,MAX(s.end_ms) end
      FROM hk_samples s JOIN hk_sources src ON src.id=s.source_id WHERE s.kind=1 AND s.type_id=(SELECT id FROM hk_types WHERE identifier=?) GROUP BY src.name`, SLEEP_TYPE)) {
      this.sleepWindows.push({ source: r.source, start: r.start, end: r.end });
    }
    for (const r of all<{ day: string; source: string }>("SELECT DISTINCT day,source FROM hk_sleep_members")) this.sleepAffected.set(JSON.stringify([r.day, r.source]), r);
  }

  private workout(id: string) {
    const r = one<RawRow>("SELECT * FROM hk_raw WHERE uuid=? AND kind='workout'", id);
    if (!r || r.deleted_at !== null) {
      // Remove a native row if its UUID changed kind; overlapping HAE workouts retain their ownership.
      run("DELETE FROM hk_workouts WHERE id=? AND payload_id IN (SELECT id FROM payloads WHERE origin='v2')", id); return;
    }
    const extra = JSON.parse(r.extra_json) as Extract<Sample, { kind: "workout" }>;
    const statistic = extra.statistics[HR_TYPE];
    let hr: { min: number | null; avg: number | null; max: number | null };
    if (statistic) {
      const cv = (v: number | null | undefined) => v == null ? null : nativeValue("heart_rate", v, statistic.unit);
      hr = { min: cv(statistic.min), avg: cv(statistic.avg), max: cv(statistic.max) };
    } else {
      const values = ownOrAll(heartReadings(r.start_ms, r.end_ms), r.source_name, r.source_bundle).map((h) => h.bpm);
      let min = Infinity, max = -Infinity, total = 0;
      for (const v of values) { min = Math.min(min, v); max = Math.max(max, v); total += v; }
      hr = { min: values.length ? min : null, avg: values.length ? total / values.length : null, max: values.length ? max : null };
    }
    const statValue = (type: string, key: string) => { const s = extra.statistics[type]; return s?.sum == null ? null : nativeValue(key, s.sum, s.unit); };
    run(`INSERT INTO hk_workouts(id,name,start,end,start_ms,end_ms,day,duration_s,active_kcal,hr_min,hr_avg,hr_max,distance_km,source,payload_id,updated_at)
      VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,start=excluded.start,end=excluded.end,start_ms=excluded.start_ms,
      end_ms=excluded.end_ms,day=excluded.day,duration_s=excluded.duration_s,active_kcal=excluded.active_kcal,hr_min=excluded.hr_min,hr_avg=excluded.hr_avg,
      hr_max=excluded.hr_max,distance_km=excluded.distance_km,source=excluded.source,payload_id=excluded.payload_id,updated_at=excluded.updated_at`,
      id, extra.activity_name, r.start_iso, r.end_iso, r.start_ms, r.end_ms, dayAt(r.start_ms, r.start_iso, r.tz), extra.duration_s,
      statValue("HKQuantityTypeIdentifierActiveEnergyBurned", "active_kcal"), hr.min, hr.avg, hr.max,
      statValue(Object.keys(extra.statistics).find((t) => t.startsWith("HKQuantityTypeIdentifierDistance")) ?? "", "distance_km"), r.source_name, this.payloadId, now());
  }
}

export type Projection = { day: string | null; value: number | null; days: { day: string; n: number; total: number; min: number; max: number }[] };
export function projectSample(s: Sample): Projection {
  const empty: Projection = { day: null, value: null, days: [] }, m = HK_METRICS.get(s.type);
  if (!m) return empty;
  if (s.type === STAND_TYPE && s.kind === "category") return { day: dayAt(Date.parse(s.start), s.start, s.tz), value: s.value === 0 ? 1 : 0, days: [] };
  if (s.kind !== "quantity") return empty;
  const points = s.series?.length ? s.series : [[s.start, s.end, s.value] as [string, string, number]];
  const days = new Map<string, Projection["days"][number]>();
  for (const [start, end, value] of points) {
    const v = nativeValue(m.def.key, value, s.unit); if (v === null) continue;
    const from = Date.parse(start), to = Date.parse(end);
    const parts = m.cumulative ? splitDays(from, to, start, s.tz) : [{ day: dayAt(from, start, s.tz), fraction: 1 }];
    for (const p of parts) {
      const n = v * p.fraction, current = days.get(p.day);
      if (current) { current.n++; current.total += n; current.min = Math.min(current.min, n); current.max = Math.max(current.max, n); }
      else days.set(p.day, { day: p.day, n: 1, total: n, min: n, max: n });
    }
  }
  const values = [...days.values()];
  if (values.length === 1 && values[0].n === 1) return { day: values[0].day, value: values[0].total, days: [] };
  return { day: null, value: null, days: values };
}
