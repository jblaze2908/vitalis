// Health Auto Export pushes (REST automation, JSON v2, Time Grouping: Day, Summarize Data on) and the same JSON from a
// manual export. The raw body is stored before anything is parsed; parsing never fails a push for one bad metric.
// Upserts make re-sends harmless: the default range resends today's partial day, and the later value wins.
import { createHash } from "node:crypto";
import { gunzipSync, gzipSync } from "node:zlib";
import { BY_HAE, convert } from "./catalog.js";
import { httpErr, now } from "./config.js";
import { all, one, run, tx } from "./db.js";
import { localDay, parseStamp } from "./time.js";

export type IngestMeta = { origin: string; automation?: string | null; aggregation?: string | null; period?: string | null };
export type IngestResult = { payload_id: number; duplicate: boolean; counts: Counts; warnings: string[]; new_nights?: string[] };
type Counts = { metric_days: number; sleep_nights: number; workouts: number; skipped_metrics: number };

type Row = Record<string, unknown>;
const num = (v: unknown) => (typeof v === "number" && Number.isFinite(v) ? v : typeof v === "string" && v.trim() !== "" && Number.isFinite(+v) ? +v : null);
const str = (v: unknown) => (typeof v === "string" ? v : "");
const qtyOf = (v: unknown) => (v && typeof v === "object" ? num((v as Row).qty) : num(v));
const unitOf = (v: unknown) => (v && typeof v === "object" ? str((v as Row).units) : "");

export function ingest(body: Buffer, meta: IngestMeta): IngestResult {
  let parsed: unknown;
  try { parsed = JSON.parse(body.toString("utf8")); } catch { throw httpErr(400, "Body is not JSON. Set the automation's Export Format to JSON."); }
  const data = (parsed as Row)?.data;
  if (!data || typeof data !== "object") throw httpErr(400, "Expected Health Auto Export JSON: {\"data\": {\"metrics\": [...], \"workouts\": [...]}}");
  const sha = createHash("sha256").update(body).digest("hex");
  const dup = one<{ id: number; counts: string | null; warnings: string | null }>("SELECT id,counts,warnings FROM payloads WHERE sha256=?", sha);
  if (dup) return { payload_id: dup.id, duplicate: true, counts: JSON.parse(dup.counts ?? "null") ?? zero(), warnings: JSON.parse(dup.warnings ?? "[]") };
  const id = Number(run("INSERT INTO payloads(received_at,origin,sha256,bytes,body_gz,automation,aggregation,period) VALUES(?,?,?,?,?,?,?,?)",
    now(), meta.origin, sha, body.length, gzipSync(body), meta.automation ?? null, meta.aggregation ?? null, meta.period ?? null).lastInsertRowid);
  return apply(id, data as Row);
}

/** Parse a stored payload again (after a parser fix). */
export function reparse(id: number): IngestResult {
  const p = one<{ body_gz: Uint8Array }>("SELECT body_gz FROM payloads WHERE id=?", id);
  if (!p) throw httpErr(404, `No payload ${id}`);
  return apply(id, (JSON.parse(gunzipSync(p.body_gz).toString("utf8")) as Row).data as Row);
}
export const payloadIds = () => all<{ id: number }>("SELECT id FROM payloads ORDER BY id").map((r) => r.id);

const zero = (): Counts => ({ metric_days: 0, sleep_nights: 0, workouts: 0, skipped_metrics: 0 });

function apply(id: number, data: Row): IngestResult {
  const counts = zero(), warnings: string[] = [], newNights: string[] = [];
  try {
    tx(() => {
      for (const m of Array.isArray(data.metrics) ? (data.metrics as Row[]) : []) {
        const name = str(m.name);
        try {
          if (name === "sleep_analysis") counts.sleep_nights += sleep(id, m, warnings, newNights);
          else { const n = metric(id, m, warnings); if (n < 0) counts.skipped_metrics++; else counts.metric_days += n; }
        } catch (e) { counts.skipped_metrics++; warnings.push(`${name || "unnamed metric"}: ${(e as Error).message}`); }
      }
      for (const w of Array.isArray(data.workouts) ? (data.workouts as Row[]) : []) {
        try { if (workout(id, w)) counts.workouts++; } catch (e) { warnings.push(`workout ${str(w.id) || "?"}: ${(e as Error).message}`); }
      }
    });
    run("UPDATE payloads SET parsed_at=?,counts=?,warnings=?,error=NULL WHERE id=?", now(), JSON.stringify(counts), JSON.stringify(warnings), id);
  } catch (e) {
    // The raw body is safe; record why and let the push succeed so the phone doesn't retry forever.
    run("UPDATE payloads SET error=? WHERE id=?", (e as Error).message.slice(0, 500), id);
    warnings.push(`not parsed: ${(e as Error).message}`);
  }
  return { payload_id: id, duplicate: false, counts, warnings, new_nights: newNights };
}

/** Rows written, or -1 when the metric was skipped. */
function metric(id: number, m: Row, warnings: string[]): number {
  const name = str(m.name), units = str(m.units), def = BY_HAE.get(name);
  const rows = Array.isArray(m.data) ? (m.data as Row[]) : [];
  const parsed: { day: string; source: string; qty: number | null; min: number | null; avg: number | null; max: number | null }[] = [];
  const seen = new Set<string>();
  for (const r of rows) {
    const t = parseStamp(r.date);
    if (!t) continue;
    // A day-grouped value is stamped local midnight, however the phone's locale writes it ("12:00:00 AM" included).
    if ((t.ms + t.offsetMin * 60_000) % 86_400_000 !== 0) {
      warnings.push(`${name}: sent per hour or finer; set the automation's Time Grouping to Day`);
      return -1;
    }
    const source = str(r.source), k = `${t.day}|${source}`;
    if (seen.has(k)) { warnings.push(`${name}: two values for ${t.day}; set Time Grouping to Day`); return -1; }
    seen.add(k);
    const c = (v: unknown) => { const n = num(v); return n === null ? null : convert(def, n, units); };
    const row = { day: t.day, source, qty: c(r.qty), min: c(r.Min ?? r.min), avg: c(r.Avg ?? r.avg), max: c(r.Max ?? r.max) };
    if (def && units && row.qty === null && row.avg === null && (num(r.qty) !== null || num(r.Avg) !== null)) {
      warnings.push(`${name}: unit "${units}" isn't one Vitalis converts; skipped`);
      return -1;
    }
    if (row.qty === null && row.avg === null && row.min === null && row.max === null) continue;
    parsed.push(row);
  }
  const key = def?.key ?? name, unit = def?.unit ?? units;
  for (const r of parsed) {
    run(`INSERT INTO metric_days(metric,day,source,qty,min,avg,max,unit,payload_id,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?)
         ON CONFLICT(metric,day,source) DO UPDATE SET qty=excluded.qty,min=excluded.min,avg=excluded.avg,max=excluded.max,unit=excluded.unit,
         payload_id=excluded.payload_id,updated_at=excluded.updated_at`, key, r.day, r.source, r.qty, r.min, r.avg, r.max, unit, id, now());
  }
  return parsed.length;
}

function sleep(id: number, m: Row, warnings: string[], newNights: string[]): number {
  let n = 0;
  for (const r of Array.isArray(m.data) ? (m.data as Row[]) : []) {
    if (r.startDate !== undefined && r.date === undefined) {
      warnings.push("sleep_analysis: sent as individual stages; turn on Summarize Data");
      return n;
    }
    const t = parseStamp(r.date);
    if (!t) continue;
    const stage = (k: string) => num(r[k]) ?? 0;
    // Stage hours are what Apple Health shows as Time Asleep; totalSleep and inBed are sometimes 0 or nested.
    const staged = stage("core") + stage("deep") + stage("rem") + stage("asleep");
    const asleep = staged > 0 ? staged : stage("totalSleep");
    if (asleep <= 0) continue;
    const at = (k: string) => parseStamp(r[k])?.iso ?? null;
    if (!one("SELECT 1 FROM sleep_nights WHERE day=?", t.day)) newNights.push(t.day);
    run(`INSERT INTO sleep_nights(day,source,sleep_start,sleep_end,in_bed_start,in_bed_end,asleep_h,core_h,deep_h,rem_h,awake_h,payload_id,updated_at)
         VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(day,source) DO UPDATE SET sleep_start=excluded.sleep_start,sleep_end=excluded.sleep_end,
         in_bed_start=excluded.in_bed_start,in_bed_end=excluded.in_bed_end,asleep_h=excluded.asleep_h,core_h=excluded.core_h,deep_h=excluded.deep_h,
         rem_h=excluded.rem_h,awake_h=excluded.awake_h,payload_id=excluded.payload_id,updated_at=excluded.updated_at`,
      t.day, str(r.source), at("sleepStart"), at("sleepEnd"), at("inBedStart"), at("inBedEnd"), asleep,
      num(r.core), num(r.deep), num(r.rem), num(r.awake), id, now());
    n++;
  }
  return n;
}

function workout(id: number, w: Row): boolean {
  const wid = str(w.id), s = parseStamp(w.start), e = parseStamp(w.end);
  if (!wid || !s || !e) return false;
  const act = Array.isArray(w.activities) ? ((w.activities as Row[])[0]?.metrics as Row | undefined) : undefined;
  const hr = (w.heartRate ?? {}) as Row;
  const pick = (top: unknown, nested: string) => qtyOf(top) ?? (act ? qtyOf(act[nested]) : null);
  const energy = w.activeEnergyBurned ?? w.activeEnergy;
  const kcal = qtyOf(energy) === null ? null : convert(BY_HAE.get("active_energy"), qtyOf(energy)!, unitOf(energy) || "kcal");
  const dist = qtyOf(w.distance) === null ? null : convert(BY_HAE.get("walking_running_distance"), qtyOf(w.distance)!, unitOf(w.distance) || "km");
  const source = typeof w.source === "object" && w.source ? str((w.source as Row).name) : str(w.source);
  run(`INSERT INTO hk_workouts(id,name,start,end,start_ms,end_ms,day,duration_s,active_kcal,hr_min,hr_avg,hr_max,distance_km,source,payload_id,updated_at)
       VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,start=excluded.start,end=excluded.end,
       start_ms=excluded.start_ms,end_ms=excluded.end_ms,day=excluded.day,duration_s=excluded.duration_s,active_kcal=excluded.active_kcal,
       hr_min=excluded.hr_min,hr_avg=excluded.hr_avg,hr_max=excluded.hr_max,distance_km=excluded.distance_km,source=excluded.source,
       payload_id=excluded.payload_id,updated_at=excluded.updated_at`,
    wid, str(w.name) || "Workout", s.iso, e.iso, s.ms, e.ms, localDay(s.ms, s.offsetMin), num(w.duration) ?? (e.ms - s.ms) / 1000, kcal,
    pick(hr.min, "heartRateMinimum"), pick(hr.avg, "heartRateAverage"), pick(hr.max, "heartRateMaximum"), dist, source, id, now());
  return true;
}
