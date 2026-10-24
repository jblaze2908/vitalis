-- Verbatim DDL of the first v2 layout (commit dcfe6d3, app/src/db.ts): payloads without codec, and the old hk_* tables.
CREATE TABLE IF NOT EXISTS payloads (
  id INTEGER PRIMARY KEY AUTOINCREMENT, received_at INTEGER NOT NULL, origin TEXT NOT NULL, sha256 TEXT NOT NULL UNIQUE,
  bytes INTEGER NOT NULL, body_gz BLOB NOT NULL, automation TEXT, aggregation TEXT, period TEXT,
  parsed_at INTEGER, counts TEXT, warnings TEXT, error TEXT);
CREATE INDEX IF NOT EXISTS payloads_received ON payloads(received_at);
CREATE TABLE IF NOT EXISTS hk_samples (
  uuid TEXT PRIMARY KEY, type TEXT NOT NULL, kind TEXT NOT NULL, start_ms INTEGER NOT NULL, end_ms INTEGER NOT NULL,
  start_iso TEXT NOT NULL, end_iso TEXT NOT NULL, tz TEXT, value REAL, unit TEXT, category_value INTEGER,
  source_name TEXT NOT NULL, source_bundle TEXT NOT NULL, source_json TEXT NOT NULL, device_json TEXT,
  metadata_json TEXT, extra_json TEXT NOT NULL, content_hash TEXT NOT NULL, payload_id INTEGER NOT NULL,
  created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, deleted_at INTEGER);
CREATE INDEX IF NOT EXISTS hk_samples_start ON hk_samples(type, start_ms);
CREATE INDEX IF NOT EXISTS hk_samples_end ON hk_samples(type, end_ms);
CREATE INDEX IF NOT EXISTS hk_samples_source ON hk_samples(type, source_name, start_ms, end_ms);
CREATE TABLE IF NOT EXISTS hk_tombstones (
  uuid TEXT PRIMARY KEY, type TEXT NOT NULL, deleted_at INTEGER NOT NULL, payload_id INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS hk_quantity_points (
  uuid TEXT NOT NULL REFERENCES hk_samples(uuid), ord INTEGER NOT NULL, start_iso TEXT NOT NULL, end_iso TEXT NOT NULL,
  start_ms INTEGER NOT NULL, end_ms INTEGER NOT NULL, value REAL NOT NULL, PRIMARY KEY(uuid, ord));
CREATE TABLE IF NOT EXISTS hk_route_points (
  uuid TEXT NOT NULL REFERENCES hk_samples(uuid), ord INTEGER NOT NULL, time_iso TEXT NOT NULL,
  lat REAL NOT NULL, lon REAL NOT NULL, alt_m REAL NOT NULL, h_acc_m REAL NOT NULL, v_acc_m REAL NOT NULL,
  speed_mps REAL NOT NULL, course_deg REAL NOT NULL, PRIMARY KEY(uuid, ord));
CREATE TABLE IF NOT EXISTS hk_heartbeat_beats (
  uuid TEXT NOT NULL REFERENCES hk_samples(uuid), ord INTEGER NOT NULL, seconds REAL NOT NULL,
  preceded_by_gap INTEGER NOT NULL, PRIMARY KEY(uuid, ord));
-- Disposable projection: split cumulative intervals at local midnight, use series points once for discrete values.
CREATE TABLE IF NOT EXISTS hk_sample_values (
  uuid TEXT NOT NULL REFERENCES hk_samples(uuid), ord INTEGER NOT NULL, metric TEXT NOT NULL, day TEXT NOT NULL,
  source TEXT NOT NULL, source_bundle TEXT NOT NULL, value REAL NOT NULL, start_ms INTEGER NOT NULL, end_ms INTEGER NOT NULL,
  PRIMARY KEY(uuid, ord));
CREATE INDEX IF NOT EXISTS hk_values_day ON hk_sample_values(metric, day, source);
CREATE INDEX IF NOT EXISTS hk_values_time ON hk_sample_values(metric, source, source_bundle, start_ms, end_ms);
CREATE TABLE IF NOT EXISTS hk_sleep_members (
  uuid TEXT PRIMARY KEY REFERENCES hk_samples(uuid), day TEXT NOT NULL, source TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS hk_sleep_day ON hk_sleep_members(day, source);
CREATE TABLE IF NOT EXISTS hk_daily_stats (
  type TEXT NOT NULL, day TEXT NOT NULL, content_json TEXT NOT NULL, payload_id INTEGER NOT NULL,
  updated_at INTEGER NOT NULL, PRIMARY KEY(type, day));
CREATE TABLE IF NOT EXISTS hk_batches (
  batch_id TEXT PRIMARY KEY, payload_id INTEGER NOT NULL, received_at INTEGER NOT NULL,
  counts_json TEXT NOT NULL, rejected_json TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS hk_batches_received ON hk_batches(received_at);
