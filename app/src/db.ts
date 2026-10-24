// One SQLite file. WAL + synchronous=NORMAL: a power cut can lose the last commits, never corrupt the file.
import { DatabaseSync, type SQLInputValue } from "node:sqlite";
import { join } from "node:path";
import { profile } from "./v2-profile.js";
import { rebuildISO } from "./v2-time.js";
import { ROOT } from "./config.js";

export const db = new DatabaseSync(process.env.VITALIS_DB ?? join(ROOT, "vitalis.db"));
// Keep existing files' page size; choose the measured 4K layout only before a fresh file gets pages.
if (db.prepare("PRAGMA page_count").get()!.page_count === 0) db.exec("PRAGMA page_size=4096");
db.exec(`PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA busy_timeout=3000; PRAGMA foreign_keys=ON;
  PRAGMA cache_size=-65536; PRAGMA mmap_size=268435456; PRAGMA temp_store=MEMORY; PRAGMA wal_autocheckpoint=8192;`);

db.exec(`
CREATE TABLE IF NOT EXISTS tokens (
  id TEXT PRIMARY KEY, name TEXT NOT NULL, scope TEXT NOT NULL CHECK (scope IN ('ingest','read','write')),
  hash TEXT NOT NULL UNIQUE, prefix TEXT NOT NULL, created_at INTEGER NOT NULL, last_used_at INTEGER, revoked_at INTEGER);

-- Every push is retained before parsing for replay: gzip for HAE, codec-marked compression for v2.
CREATE TABLE IF NOT EXISTS payloads (
  id INTEGER PRIMARY KEY AUTOINCREMENT, received_at INTEGER NOT NULL, origin TEXT NOT NULL, sha256 TEXT NOT NULL UNIQUE,
  bytes INTEGER NOT NULL, body_gz BLOB NOT NULL, automation TEXT, aggregation TEXT, period TEXT,
  parsed_at INTEGER, counts TEXT, warnings TEXT, error TEXT);
CREATE INDEX IF NOT EXISTS payloads_received ON payloads(received_at);

-- Undeployed v2 ledger: compact integer keys; existing production tables below remain compatible.
CREATE TABLE IF NOT EXISTS hk_types (
  id INTEGER PRIMARY KEY, identifier TEXT NOT NULL UNIQUE, metric TEXT, cumulative INTEGER NOT NULL DEFAULT 0,
  duration_ms INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS hk_sources (
  id INTEGER PRIMARY KEY, name TEXT NOT NULL, bundle TEXT NOT NULL, json TEXT NOT NULL UNIQUE);
CREATE INDEX IF NOT EXISTS hk_sources_name ON hk_sources(name);
CREATE TABLE IF NOT EXISTS hk_devices (id INTEGER PRIMARY KEY, json TEXT NOT NULL UNIQUE);
CREATE TABLE IF NOT EXISTS hk_samples (
  id INTEGER PRIMARY KEY, uuid TEXT NOT NULL UNIQUE, type_id INTEGER NOT NULL REFERENCES hk_types(id), kind INTEGER,
  start_ms INTEGER, end_ms INTEGER, start_offset INTEGER, end_offset INTEGER, start_format INTEGER, end_format INTEGER,
  tz TEXT, value REAL, unit TEXT, category_value INTEGER, source_id INTEGER REFERENCES hk_sources(id), device_id INTEGER REFERENCES hk_devices(id),
  json TEXT, day TEXT, native_value REAL, content_hash BLOB NOT NULL, payload_id INTEGER NOT NULL,
  created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, deleted_at INTEGER);
CREATE INDEX IF NOT EXISTS hk_samples_time ON hk_samples(type_id,end_ms,start_ms) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS hk_samples_day ON hk_samples(type_id,day,source_id) WHERE day IS NOT NULL AND native_value IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS hk_samples_sleep ON hk_samples(source_id,start_ms,end_ms) WHERE kind=1 AND deleted_at IS NULL;
CREATE TABLE IF NOT EXISTS hk_tombstones (
  uuid TEXT PRIMARY KEY, type TEXT NOT NULL, deleted_at INTEGER NOT NULL, payload_id INTEGER NOT NULL) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS hk_type_status (
  type TEXT PRIMARY KEY, live INTEGER NOT NULL DEFAULT 0, deleted INTEGER NOT NULL DEFAULT 0, newest_end TEXT) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS hk_sleep_bounds (source TEXT PRIMARY KEY, duration_ms INTEGER NOT NULL) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS hk_blobs (sample_id INTEGER PRIMARY KEY REFERENCES hk_samples(id), data BLOB NOT NULL, start_ms INTEGER, end_ms INTEGER);
CREATE INDEX IF NOT EXISTS hk_blobs_window ON hk_blobs(end_ms,start_ms) WHERE end_ms IS NOT NULL;
-- Exceptions only: series aggregate to one row per day, and cumulative intervals crossing midnight split by day.
-- Ordinary scalar values use the indexed raw row directly, with no second per-sample projection.
CREATE TABLE IF NOT EXISTS hk_value_days (
  sample_id INTEGER NOT NULL REFERENCES hk_samples(id), day TEXT NOT NULL, n INTEGER NOT NULL, total REAL NOT NULL,
  min REAL NOT NULL, max REAL NOT NULL, PRIMARY KEY(sample_id,day)) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS hk_value_days_day ON hk_value_days(day,sample_id);
CREATE TABLE IF NOT EXISTS hk_sleep_members (
  uuid TEXT PRIMARY KEY, day TEXT NOT NULL, source TEXT NOT NULL) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS hk_sleep_day ON hk_sleep_members(day,source);
CREATE TABLE IF NOT EXISTS hk_daily_stats (
  type TEXT NOT NULL, day TEXT NOT NULL, content_json TEXT NOT NULL, payload_id INTEGER NOT NULL,
  updated_at INTEGER NOT NULL, PRIMARY KEY(type,day)) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS hk_batches (
  batch_id TEXT PRIMARY KEY, payload_id INTEGER NOT NULL, received_at INTEGER NOT NULL,
  counts_json TEXT NOT NULL, rejected_json TEXT NOT NULL) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS hk_batches_received ON hk_batches(received_at);

-- One value per metric, local day and source. source '' is Apple Health's merged total (steps, energy).
CREATE TABLE IF NOT EXISTS metric_days (
  metric TEXT NOT NULL, day TEXT NOT NULL, source TEXT NOT NULL, qty REAL, min REAL, avg REAL, max REAL,
  unit TEXT NOT NULL, payload_id INTEGER, updated_at INTEGER NOT NULL, PRIMARY KEY (metric, day, source));
CREATE INDEX IF NOT EXISTS metric_days_day ON metric_days(day);

-- One row per night, keyed by the day the sleeper woke up. Hours per stage; times as ISO with offset.
CREATE TABLE IF NOT EXISTS sleep_nights (
  day TEXT NOT NULL, source TEXT NOT NULL, sleep_start TEXT, sleep_end TEXT, in_bed_start TEXT, in_bed_end TEXT,
  asleep_h REAL NOT NULL, core_h REAL, deep_h REAL, rem_h REAL, awake_h REAL, payload_id INTEGER, updated_at INTEGER NOT NULL,
  PRIMARY KEY (day, source));

CREATE TABLE IF NOT EXISTS hk_workouts (
  id TEXT PRIMARY KEY, name TEXT NOT NULL, start TEXT NOT NULL, end TEXT NOT NULL, start_ms INTEGER NOT NULL, end_ms INTEGER NOT NULL,
  day TEXT NOT NULL, duration_s REAL NOT NULL, active_kcal REAL, hr_min REAL, hr_avg REAL, hr_max REAL, distance_km REAL,
  source TEXT, payload_id INTEGER, updated_at INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS hk_workouts_start ON hk_workouts(start_ms);
CREATE INDEX IF NOT EXISTS hk_workouts_source_window ON hk_workouts(source, start_ms, end_ms);

CREATE TABLE IF NOT EXISTS exercises (
  id TEXT PRIMARY KEY, name TEXT NOT NULL, equipment TEXT, mechanic TEXT, category TEXT,
  primary_muscles TEXT NOT NULL, secondary_muscles TEXT NOT NULL, aliases TEXT NOT NULL DEFAULT '[]',
  custom INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL);

-- Strength sessions. Times are UTC ms plus the offset they were logged in, so a session can cross midnight.
CREATE TABLE IF NOT EXISTS sessions (
  id TEXT PRIMARY KEY, title TEXT, started_at INTEGER NOT NULL, ended_at INTEGER, tz_offset_min INTEGER NOT NULL,
  notes TEXT, source TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, deleted_at INTEGER);
CREATE INDEX IF NOT EXISTS sessions_started ON sessions(started_at);

-- ids come from the client, so a retried write is a no-op. kind 'warmup' never counts toward volume or records.
CREATE TABLE IF NOT EXISTS sets (
  id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id), exercise_id TEXT NOT NULL REFERENCES exercises(id),
  ord INTEGER NOT NULL, kind TEXT NOT NULL CHECK (kind IN ('warmup','normal','drop','failure')),
  weight_kg REAL, reps INTEGER, duration_s REAL, distance_m REAL, rpe REAL, rir INTEGER,
  target_weight_kg REAL, target_reps INTEGER, performed_at INTEGER NOT NULL, note TEXT,
  created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, deleted_at INTEGER);
CREATE INDEX IF NOT EXISTS sets_session ON sets(session_id, ord);
CREATE INDEX IF NOT EXISTS sets_exercise ON sets(exercise_id, performed_at);

-- Outbound events, one per (event, day), so a resent push never fires twice.
CREATE TABLE IF NOT EXISTS hook_events (
  event TEXT NOT NULL, day TEXT NOT NULL, created_at INTEGER NOT NULL, sent_at INTEGER, status TEXT, attempts INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (event, day));

-- Append-only record of every MCP call and push: who, what, outcome. Counts only, never values.
CREATE TABLE IF NOT EXISTS calls (
  id INTEGER PRIMARY KEY AUTOINCREMENT, at INTEGER NOT NULL, token_id TEXT, tool TEXT NOT NULL, ok INTEGER NOT NULL,
  ms INTEGER NOT NULL, detail TEXT);
CREATE INDEX IF NOT EXISTS calls_at ON calls(at);
`);

// Additive retention codec marker: all existing HAE and gzip-native payloads keep their original bytes.
const hasCodec = () => db.prepare("PRAGMA table_info(payloads)").all().some(c => c.name === "codec");
if (!hasCodec()) {
  try { db.exec("ALTER TABLE payloads ADD COLUMN codec TEXT NOT NULL DEFAULT 'gzip'"); }
  catch (e) { if (!hasCodec()) throw e; } // another connection may have added it while this one waited
}

// Bound dynamic-query growth while reusing the hot statements on this connection.
const statements = new Map<string, ReturnType<typeof db.prepare>>();
export function statement(sql: string) {
  let s = statements.get(sql);
  if (!s) {
    s = db.prepare(sql);
    if (statements.size >= 512) statements.delete(statements.keys().next().value!);
    statements.set(sql, s);
  }
  return s;
}
export const run = (sql: string, ...p: SQLInputValue[]) => {
  if (!profile) return statement(sql).run(...p);
  const t = performance.now(); try { return statement(sql).run(...p); } finally { profile.sqlite += performance.now() - t; }
};
export const one = <T>(sql: string, ...p: SQLInputValue[]): T | undefined => {
  if (!profile) return statement(sql).get(...p) as T | undefined;
  const t = performance.now(); try { return statement(sql).get(...p) as T | undefined; } finally { profile.sqlite += performance.now() - t; }
};
export const all = <T>(sql: string, ...p: SQLInputValue[]): T[] => {
  if (!profile) return statement(sql).all(...p) as T[];
  const t = performance.now(); try { return statement(sql).all(...p) as T[]; } finally { profile.sqlite += performance.now() - t; }
};
export const marks = (n: number) => Array(n).fill("?").join(",");

function transactionSQL(sql: string) {
  if (!profile) { db.exec(sql); return; }
  const t = performance.now(); try { db.exec(sql); } finally { profile.sqlite += performance.now() - t; }
}
export function tx<T>(fn: () => T): T {
  transactionSQL("BEGIN IMMEDIATE");
  try { const r = fn(); transactionSQL("COMMIT"); return r; } catch (e) {
    // SQLite can roll back automatically (e.g. SQLITE_FULL); preserve the original failure.
    try { transactionSQL("ROLLBACK"); } catch { /* already rolled back */ }
    throw e;
  }
}

// Read views reconstruct wire times and source fields only when selected. No duplicated ISO/source JSON per sample.
db.function("hk_iso", (ms, offset, format, original) => ms === null ? null : rebuildISO(Number(ms), Number(offset), Number(format), typeof original === "string" ? original : undefined));
db.exec(`
CREATE VIEW IF NOT EXISTS hk_raw AS SELECT s.id,s.uuid,t.identifier type,
  CASE s.kind WHEN 0 THEN 'quantity' WHEN 1 THEN 'category' WHEN 2 THEN 'workout' WHEN 3 THEN 'route'
    WHEN 4 THEN 'heartbeat' WHEN 5 THEN 'ecg' WHEN 6 THEN 'correlation' WHEN 7 THEN 'state_of_mind' ELSE 'other' END kind,
  s.type_id,s.source_id,s.start_ms,s.end_ms,b.start_ms series_start,b.end_ms series_end,
  hk_iso(s.start_ms,s.start_offset,s.start_format,json_extract(s.json,'$.times.start')) start_iso,
  hk_iso(s.end_ms,s.end_offset,s.end_format,json_extract(s.json,'$.times.end')) end_iso,
  s.tz,s.value,s.unit,s.category_value,COALESCE(src.name,'') source_name,COALESCE(src.bundle,'') source_bundle,
  src.json source_json,d.json device_json,json_extract(s.json,'$.metadata') metadata_json,
  CASE WHEN s.kind IS NULL THEN '{}' ELSE json_set(COALESCE(json_extract(s.json,'$.extra'),'{}'),'$.kind',
    CASE s.kind WHEN 0 THEN 'quantity' WHEN 1 THEN 'category' WHEN 2 THEN 'workout' WHEN 3 THEN 'route'
      WHEN 4 THEN 'heartbeat' WHEN 5 THEN 'ecg' WHEN 6 THEN 'correlation' WHEN 7 THEN 'state_of_mind' ELSE 'other' END) END extra_json,
  lower(hex(s.content_hash)) content_hash,s.payload_id,s.created_at,s.updated_at,s.deleted_at
FROM hk_samples s JOIN hk_types t ON t.id=s.type_id LEFT JOIN hk_sources src ON src.id=s.source_id LEFT JOIN hk_devices d ON d.id=s.device_id LEFT JOIN hk_blobs b ON b.sample_id=s.id;
CREATE VIEW IF NOT EXISTS hk_values AS
SELECT s.uuid,s.id sample_id,t.metric,s.day,src.name source,src.bundle source_bundle,s.native_value total,1 n,
  s.native_value min,s.native_value max,s.start_ms,s.end_ms
FROM hk_samples s JOIN hk_types t ON t.id=s.type_id JOIN hk_sources src ON src.id=s.source_id
WHERE s.deleted_at IS NULL AND s.day IS NOT NULL AND s.native_value IS NOT NULL
UNION ALL
SELECT s.uuid,s.id,t.metric,v.day,src.name,src.bundle,v.total,v.n,v.min,v.max,s.start_ms,s.end_ms
FROM hk_value_days v JOIN hk_samples s ON s.id=v.sample_id JOIN hk_types t ON t.id=s.type_id JOIN hk_sources src ON src.id=s.source_id
WHERE s.deleted_at IS NULL;
`);
// Read endpoints must not wait on the ingest worker's write lock merely to record audit metadata.
const auditQueue: { sql: string; params: SQLInputValue[] }[] = [];
let auditTimer: NodeJS.Timeout | undefined;
function tryAudit(sql: string, params: SQLInputValue[]) {
  db.exec('PRAGMA busy_timeout=0');
  try { run(sql, ...params); return true; }
  catch (e) { if ([5, 6].includes(((e as { errcode?: number }).errcode ?? 0) & 255)) return false; throw e; }
  finally { db.exec('PRAGMA busy_timeout=3000'); }
}
export function flushAudits() {
  if (auditTimer) { clearTimeout(auditTimer); auditTimer = undefined; }
  while (auditQueue.length) {
    const { sql, params } = auditQueue[0];
    if (!tryAudit(sql, params)) break;
    auditQueue.shift();
  }
  if (auditQueue.length) auditTimer = setTimeout(flushAudits, 10).unref();
}
export function auditWrite(sql: string, ...params: SQLInputValue[]) {
  if (tryAudit(sql, params)) return;
  auditQueue.push({ sql, params });
  if (!auditTimer) auditTimer = setTimeout(flushAudits, 10).unref();
}
