import { BY_KEY } from "./catalog.js";
import { now } from "./config.js";
import { all, one, run } from "./db.js";
import { dayAt, HK_METRICS, HR_TYPE, nativeValue, SLEEP_TYPE, splitDays, STAND_TYPE } from "./v2-metrics.js";
import { blobFor, unpack } from "./v2-storage.js";
import type { DailyStat, Sample } from "./v2-schema.js";

export type RawRow = { id: number; type_id: number; source_id: number | null; uuid: string; type: string; kind: Sample["kind"]; start_ms: number; end_ms: number; start_iso: string; end_iso: string;
  tz: string | null; source_name: string; source_bundle: string; category_value: number | null; extra_json: string; content_hash: string; payload_id: number; deleted_at: number | null };
type MetricGroup = { metric: string; day: string; source: string };
type Window = { source: string; start: number; end: number };
const HOUR = 3_600_000;

export class Derivations {
  private metrics = new Map<string, MetricGroup>();
  private sleepWindows: Window[] = [];
  private sleepAffected = new Map<string, { day: string; source: string }>();
  private sleepTouched = new Set<string>();
  private workouts = new Set<string>();
  private hrWindows: Window[] = [];
  readonly newNights: string[] = [];
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
    if (row.type === HR_TYPE) this.hrWindows.push({ source: row.source_name, start: row.start_ms, end: row.end_ms });
  }
  private group(g: MetricGroup) { this.metrics.set(JSON.stringify([g.metric, g.day, g.source]), g); }

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
    const cv = (v: number | null | undefined) => v == null ? null : s.type === STAND_TYPE && s.unit === "count" ? v : nativeValue(m.def.key, v, s.unit);
    const qty = m.cumulative ? cv(s.sum) : null, min = m.cumulative ? null : cv(s.min), avg = m.cumulative ? null : cv(s.avg), max = m.cumulative ? null : cv(s.max);
    if ([qty, min, avg, max].every((v) => v === null)) {
      run("DELETE FROM metric_days WHERE metric=? AND day=? AND source='' AND payload_id IN (SELECT id FROM payloads WHERE origin='v2')", m.def.key, s.day);
      return;
    }
    this.writeMetric(m.def.key, s.day, "", qty, min, avg, max);
  }

  finish() {
    const aggregates = all<MetricGroup & { n: number; sum: number; min: number; avg: number; max: number }>(`
      WITH touched AS (
        SELECT t.id type_id,json_extract(j.value,'$.metric') metric,json_extract(j.value,'$.day') day,json_extract(j.value,'$.source') source
        FROM json_each(?) j JOIN hk_types t ON t.metric=json_extract(j.value,'$.metric')
      ), pieces AS (
        SELECT g.metric,g.day,g.source,COUNT(*) n,SUM(s.native_value) total,MIN(s.native_value) min,MAX(s.native_value) max
        FROM touched g JOIN hk_sources src ON src.name=g.source
        JOIN hk_samples s ON s.type_id=g.type_id AND s.day=g.day AND s.source_id=src.id
        WHERE s.deleted_at IS NULL AND s.day IS NOT NULL AND s.native_value IS NOT NULL GROUP BY g.metric,g.day,g.source
        UNION ALL
        SELECT g.metric,g.day,g.source,SUM(v.n),SUM(v.total),MIN(v.min),MAX(v.max)
        FROM touched g JOIN hk_value_days v ON v.day=g.day JOIN hk_samples s ON s.id=v.sample_id AND s.type_id=g.type_id
        JOIN hk_sources src ON src.id=s.source_id AND src.name=g.source WHERE s.deleted_at IS NULL GROUP BY g.metric,g.day,g.source
      ), totals AS (SELECT metric,day,source,SUM(n) n,SUM(total) total,MIN(min) min,MAX(max) max FROM pieces GROUP BY metric,day,source)
      SELECT g.metric,g.day,g.source,COALESCE(a.n,0) n,a.total sum,a.min,a.total/a.n avg,a.max FROM touched g
      LEFT JOIN totals a ON a.metric=g.metric AND a.day=g.day AND a.source=g.source`, JSON.stringify([...this.metrics.values()]));
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

  private sleep() {
    // Expand to whole connected sessions, so changes to an early stage also move/remove its old wake-day row.
    const affected = this.sleepAffected;
    for (const { day, source } of affected.values()) {
      for (const r of all<RawRow>("SELECT s.* FROM hk_sleep_members m JOIN hk_raw s USING(uuid) WHERE m.day=? AND m.source=?", day, source)) {
        if (r.type === SLEEP_TYPE) this.sleepWindows.push({ source: r.source_name, start: r.start_ms, end: r.end_ms });
      }
    }
    for (const uuid of this.sleepTouched) run("DELETE FROM hk_sleep_members WHERE uuid=?", uuid);
    const windows = this.merge(this.sleepWindows, 3 * HOUR);
    const rows = new Map<string, RawRow>();
    for (const w of windows) {
      let from = w.start, to = w.end;
      const duration = one<{ duration_ms: number }>("SELECT duration_ms FROM hk_sleep_bounds WHERE source=?", w.source)?.duration_ms ?? 0;
      for (;;) {
        const found = all<RawRow>(`SELECT r.* FROM hk_samples s JOIN hk_raw r ON r.id=s.id
          WHERE s.kind=1 AND s.deleted_at IS NULL AND s.type_id=(SELECT id FROM hk_types WHERE identifier=?)
          AND s.source_id IN (SELECT id FROM hk_sources WHERE name=?) AND s.start_ms BETWEEN ? AND ? AND s.end_ms>=?`,
          SLEEP_TYPE, w.source, from - 3 * HOUR - duration, to + 3 * HOUR, from - 3 * HOUR);
        let nextFrom = from, nextTo = to;
        for (const r of found) {
          // Include tombstoned segments as bridges when finding the old session; never count their hours.
          rows.set(r.uuid, r); nextFrom = Math.min(nextFrom, r.start_ms); nextTo = Math.max(nextTo, r.end_ms);
          const old = one<{ day: string; source: string }>("SELECT day,source FROM hk_sleep_members WHERE uuid=?", r.uuid);
          if (old) affected.set(JSON.stringify([old.day, old.source]), old);
        }
        if (nextFrom === from && nextTo === to) break;
        from = nextFrom; to = nextTo;
      }
    }
    // The membership row also remembers the original night when a UUID changes time or source.
    for (const r of rows.values()) run("DELETE FROM hk_sleep_members WHERE uuid=?", r.uuid);
    const groups = this.merge([...rows.values()].filter((r) => r.deleted_at === null).map((r) => ({ source: r.source_name, start: r.start_ms, end: r.end_ms })), 3 * HOUR);
    const nights = new Map<string, RawRow[]>();
    for (const g of groups) {
      const members = [...rows.values()].filter((r) => r.deleted_at === null && r.source_name === g.source && r.start_ms >= g.start && r.end_ms <= g.end);
      const asleep = members.filter((r) => [1, 3, 4, 5].includes(r.category_value!));
      const last = (asleep.length ? asleep : members).reduce((a, b) => a.end_ms >= b.end_ms ? a : b);
      const day = dayAt(last.end_ms, last.end_iso, last.tz), key = JSON.stringify([day, g.source]);
      affected.set(key, { day, source: g.source }); nights.set(key, [...(nights.get(key) ?? []), ...members]);
      for (const r of members) run("INSERT INTO hk_sleep_members(uuid,day,source) VALUES(?,?,?)", r.uuid, day, g.source);
    }
    for (const [key, { day, source }] of affected) {
      const rs = nights.get(key) ?? [];
      // Another disconnected session on the same wake day (e.g. a nap) must remain included.
      for (const r of all<RawRow>(`SELECT s.* FROM hk_sleep_members m JOIN hk_raw s USING(uuid) WHERE m.day=? AND m.source=? AND s.deleted_at IS NULL`, day, source)) {
        if (!rs.some((x) => x.uuid === r.uuid)) rs.push(r);
      }
      const asleep = rs.filter((r) => [1, 3, 4, 5].includes(r.category_value!));
      if (!asleep.length) {
        run("DELETE FROM sleep_nights WHERE day=? AND source=? AND payload_id IN (SELECT id FROM payloads WHERE origin='v2')", day, source);
        continue;
      }
      const hours = (values: number[]) => this.merge(rs.filter((r) => values.includes(r.category_value!))
        .map((r) => ({ source, start: r.start_ms, end: r.end_ms }))).reduce((n, r) => n + (r.end - r.start) / HOUR, 0);
      const edge = (xs: RawRow[], end: boolean) => xs.length ? xs.reduce((a, b) => end ? (a.end_ms >= b.end_ms ? a : b) : (a.start_ms <= b.start_ms ? a : b))[end ? "end_iso" : "start_iso"] : null;
      const bed = rs.filter((r) => r.category_value === 0);
      if (!one("SELECT 1 FROM sleep_nights WHERE day=?", day)) this.newNights.push(day);
      run(`INSERT INTO sleep_nights(day,source,sleep_start,sleep_end,in_bed_start,in_bed_end,asleep_h,core_h,deep_h,rem_h,awake_h,payload_id,updated_at)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(day,source) DO UPDATE SET sleep_start=excluded.sleep_start,sleep_end=excluded.sleep_end,
        in_bed_start=excluded.in_bed_start,in_bed_end=excluded.in_bed_end,asleep_h=excluded.asleep_h,core_h=excluded.core_h,deep_h=excluded.deep_h,
        rem_h=excluded.rem_h,awake_h=excluded.awake_h,payload_id=excluded.payload_id,updated_at=excluded.updated_at`, day, source, edge(asleep, false), edge(asleep, true),
        edge(bed, false), edge(bed, true), hours([1, 3, 4, 5]),
        rs.some((r) => [3, 4, 5].includes(r.category_value!)) ? hours([3]) : null,
        rs.some((r) => [3, 4, 5].includes(r.category_value!)) ? hours([4]) : null,
        rs.some((r) => [3, 4, 5].includes(r.category_value!)) ? hours([5]) : null,
        rs.some((r) => r.category_value === 2) ? hours([2]) : null, this.payloadId, now());
    }
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
      // Use the end-time range index. The maintained maximum duration also includes unusually long series.
      const type = one<{ id: number; duration_ms: number }>("SELECT id,duration_ms FROM hk_types WHERE identifier=?", HR_TYPE);
      const readings: { source: string; bundle: string; value: number }[] = [];
      if (type) for (const h of all<RawRow & { value: number; unit: string }>(`SELECT * FROM hk_raw
        WHERE type_id=? AND deleted_at IS NULL AND end_ms BETWEEN ? AND ? AND start_ms<=?`,
        type.id, r.start_ms, r.end_ms + type.duration_ms, r.end_ms)) {
        const blob = blobFor(h.uuid);
        const points = blob ? unpack(blob) as [string, string, number][] : [[h.start_iso, h.end_iso, h.value] as [string, string, number]];
        for (const [start, end, value] of points) if (Date.parse(start) >= r.start_ms && Date.parse(start) <= r.end_ms && Date.parse(end) <= r.end_ms) {
          const v = nativeValue("heart_rate", value, h.unit); if (v !== null) readings.push({ source: h.source_name, bundle: h.source_bundle, value: v });
        }
      }
      const own = readings.filter((h) => h.source === r.source_name && h.bundle === r.source_bundle);
      const values = (own.length ? own : readings).map((h) => h.value);
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
