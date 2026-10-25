// One SQLite file. WAL + synchronous=NORMAL: a power cut can lose the last commits, never corrupt the file.
import { DatabaseSync, type SQLInputValue } from "node:sqlite";
import { join } from "node:path";
import { profile } from "./v2-profile.js";
import { rebuildISO } from "./v2-time.js";
import { ROOT } from "./config.js";
import { HK_METRICS } from "./v2-metrics.js";

export const db = new DatabaseSync(process.env.VITALIS_DB ?? join(ROOT, "vitalis.db"));
// Keep existing files' page size; choose the measured 4K layout only before a fresh file gets pages.
if (db.prepare("PRAGMA page_count").get()!.page_count === 0) db.exec("PRAGMA page_size=4096");
db.exec(`PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA busy_timeout=3000; PRAGMA foreign_keys=ON;
  PRAGMA cache_size=-65536; PRAGMA mmap_size=268435456; PRAGMA temp_store=MEMORY; PRAGMA wal_autocheckpoint=8192;`);

// The first v2 layout (dcfe6d3) keyed hk_samples by uuid with no type_id. Everything in it is derivable from payloads, so
// drop it and let the current DDL rebuild it. payloads and the non-hk tables are never touched; hk_workouts predates v2.
const OLD_LAYOUT_VIEWS = ["hk_raw", "hk_values"];
// Children before parents: foreign_keys=ON makes DROP TABLE check references.
const OLD_LAYOUT_TABLES = ["hk_quantity_points", "hk_route_points", "hk_heartbeat_beats", "hk_sample_values", "hk_sleep_members", "hk_blobs",
  "hk_value_days", "hk_samples", "hk_tombstones", "hk_daily_stats", "hk_batches", "hk_type_status", "hk_sleep_bounds", "hk_types", "hk_sources", "hk_devices"];
const oldLayout = () => {
  const cols = db.prepare("PRAGMA table_info(hk_samples)").all();
  return cols.length > 0 && !cols.some(c => c.name === "type_id");
};
if (oldLayout()) {
  db.exec("BEGIN IMMEDIATE");
  try {
    if (oldLayout()) { // another connection may have migrated while this one waited
      for (const v of OLD_LAYOUT_VIEWS) db.exec(`DROP VIEW IF EXISTS ${v}`);
      for (const t of OLD_LAYOUT_TABLES) db.exec(`DROP TABLE IF EXISTS ${t}`);
      console.warn("db: dropped the old (dcfe6d3) hk_* native layout; payloads are untouched. Run `vitalis reparse --all` to rebuild it.");
    }
    db.exec("COMMIT");
  } catch (e) { db.exec("ROLLBACK"); throw e; }
}

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

-- Sleep blocks other than the night on the same sleep day (sleep-split.ts). Kept out of the night's hours and score.
CREATE TABLE IF NOT EXISTS sleep_naps (
  day TEXT NOT NULL, source TEXT NOT NULL, start TEXT NOT NULL, end TEXT NOT NULL, asleep_h REAL NOT NULL, payload_id INTEGER, updated_at INTEGER NOT NULL,
  PRIMARY KEY (day, source, start));

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

-- Monotonic counters bumped by every write that can change a computed value; ETags are built from them.
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value INTEGER NOT NULL) WITHOUT ROWID;
INSERT OR IGNORE INTO meta(key, value) VALUES ('data_version', 0), ('targets_version', 0);

-- Owner targets and training preferences, one JSON value per key. Defaults are computed, never stored.
CREATE TABLE IF NOT EXISTS targets (
  key TEXT PRIMARY KEY, value_json TEXT NOT NULL, updated_at INTEGER NOT NULL) WITHOUT ROWID;

-- Weekly adaptive calorie targets; week_start is the local Monday.
CREATE TABLE IF NOT EXISTS kcal_targets (
  week_start TEXT PRIMARY KEY, kcal INTEGER NOT NULL, mode TEXT NOT NULL CHECK (mode IN ('initial','adaptive','fixed','kept')),
  tdee INTEGER, intake_mean INTEGER, slope_kg_day REAL, rate_kg_week REAL, intake_days INTEGER, weigh_ins INTEGER,
  reason TEXT, computed_at INTEGER NOT NULL) WITHOUT ROWID;

-- Per-day features (this day's inputs only) and cached scores (this day plus the 60 before it).
CREATE TABLE IF NOT EXISTS daily_derived (
  day TEXT PRIMARY KEY,
  asleep_h REAL, need_basis TEXT, bedtime_min REAL, bed_h REAL, wakeups INTEGER, awake_min REAL,
  hrv_ms REAL, hrv_basis TEXT CHECK (hrv_basis IN ('overnight','daily')), rhr_bpm REAL,
  steps_curve TEXT, kcal_curve TEXT,
  features_at INTEGER, features_stale INTEGER NOT NULL DEFAULT 1,
  sleep_json TEXT, recovery_json TEXT, scores_at INTEGER, scores_stale INTEGER NOT NULL DEFAULT 1) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS daily_derived_stale ON daily_derived(day) WHERE features_stale = 1 OR scores_stale = 1;

-- Manual weigh-ins from the app, projected into metric_days as source 'Vitalis manual'.
CREATE TABLE IF NOT EXISTS weight_entries (
  id TEXT PRIMARY KEY, measured_at INTEGER NOT NULL, tz_offset_min INTEGER NOT NULL, day TEXT NOT NULL,
  kg REAL NOT NULL CHECK (kg > 0 AND kg < 500), hk_uuid TEXT, created_at INTEGER NOT NULL, deleted_at INTEGER);
CREATE INDEX IF NOT EXISTS weight_entries_day ON weight_entries(day) WHERE deleted_at IS NULL;

-- Food log. meal_id groups the items of one add action, so Undo removes them together.
CREATE TABLE IF NOT EXISTS food_entries (
  id TEXT PRIMARY KEY, meal_id TEXT NOT NULL, day TEXT NOT NULL,
  slot TEXT NOT NULL CHECK (slot IN ('breakfast','lunch','snack','dinner')),
  eaten_at INTEGER NOT NULL, tz_offset_min INTEGER NOT NULL,
  name TEXT NOT NULL, portion_text TEXT, grams REAL,
  kcal REAL NOT NULL CHECK (kcal >= 0 AND kcal <= 10000), protein_g REAL, carbs_g REAL, fat_g REAL,
  source TEXT NOT NULL CHECK (source IN ('search','barcode','describe','manual','label_photo','usual','recent','saved')),
  source_ref TEXT, estimate INTEGER NOT NULL DEFAULT 0, hk_uuid TEXT,
  created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, deleted_at INTEGER);
CREATE INDEX IF NOT EXISTS food_entries_day ON food_entries(day, slot) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS food_entries_meal ON food_entries(meal_id);

CREATE TABLE IF NOT EXISTS saved_meals (
  id TEXT PRIMARY KEY, name TEXT NOT NULL, slot TEXT, items_json TEXT NOT NULL,
  created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, deleted_at INTEGER);

-- Open Food Facts results and the owner's own barcodes ('user' = typed in after a miss; kept forever).
CREATE TABLE IF NOT EXISTS food_barcodes (
  code TEXT PRIMARY KEY, status TEXT NOT NULL CHECK (status IN ('found','missing','user')),
  item_json TEXT, fetched_at INTEGER NOT NULL) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS food_search_cache (
  q TEXT NOT NULL, page INTEGER NOT NULL, results_json TEXT NOT NULL, fetched_at INTEGER NOT NULL,
  PRIMARY KEY (q, page)) WITHOUT ROWID;
`);

/** Additive column; tolerates another connection (the ingest worker) adding it while this one waited. */
function addColumn(table: string, column: string, ddl: string) {
  const has = () => db.prepare(`PRAGMA table_info(${table})`).all().some(c => c.name === column);
  if (has()) return;
  try { db.exec(`ALTER TABLE ${table} ADD COLUMN ${column} ${ddl}`); }
  catch (e) { if (!has()) throw e; }
}
// Additive retention codec marker: all existing HAE and gzip-native payloads keep their original bytes.
addColumn("payloads", "codec", "TEXT NOT NULL DEFAULT 'gzip'");
addColumn("sleep_nights", "wakeups", "INTEGER");
addColumn("sessions", "hk_workout_uuid", "TEXT");
addColumn("sessions", "template", "TEXT");
addColumn("sessions", "client_source", "TEXT");
// Owner-defined workout splits; `muscles` is a JSON array of slugs. Exercises come from the last session with that split.
db.exec(`CREATE TABLE IF NOT EXISTS splits (
  id TEXT PRIMARY KEY, name TEXT NOT NULL, muscles TEXT NOT NULL, ord INTEGER NOT NULL,
  created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, deleted_at INTEGER) WITHOUT ROWID`);
db.exec("CREATE INDEX IF NOT EXISTS sessions_hk ON sessions(hk_workout_uuid) WHERE hk_workout_uuid IS NOT NULL");

// hk_types rows are created once, but the HK_METRICS mapping can change: make the table follow it at every start.
// Rows already derived under the old mapping need `vitalis reparse --all`.
{
  const sync = db.prepare("UPDATE hk_types SET metric=?,cumulative=? WHERE identifier=? AND (metric IS NOT ? OR cumulative<>?)");
  db.exec("BEGIN IMMEDIATE");
  try {
    for (const [identifier, m] of HK_METRICS) sync.run(m.def.key, m.cumulative ? 1 : 0, identifier, m.def.key, m.cumulative ? 1 : 0);
    db.prepare(`UPDATE hk_types SET metric=NULL,cumulative=0 WHERE (metric IS NOT NULL OR cumulative<>0)
      AND identifier NOT IN (SELECT value FROM json_each(?))`).run(JSON.stringify([...HK_METRICS.keys()]));
    db.exec("COMMIT");
  } catch (e) { db.exec("ROLLBACK"); throw e; }
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

/** Called inside the writing transaction, so an ETag never names a version whose data isn't committed. */
export const bumpDataVersion = () => { run("UPDATE meta SET value=value+1 WHERE key='data_version'"); };
export const bumpTargetsVersion = () => { run("UPDATE meta SET value=value+1 WHERE key='targets_version'"); };
export function dataVersions(): { data: number; targets: number } {
  const rows = all<{ key: string; value: number }>("SELECT key,value FROM meta WHERE key IN ('data_version','targets_version')");
  const get = (k: string) => Number(rows.find((r) => r.key === k)?.value ?? 0);
  return { data: get("data_version"), targets: get("targets_version") };
}
