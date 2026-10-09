// One SQLite file. WAL + synchronous=NORMAL: a power cut can lose the last commits, never corrupt the file.
import { DatabaseSync, type SQLInputValue } from "node:sqlite";
import { join } from "node:path";
import { ROOT } from "./config.js";

export const db = new DatabaseSync(process.env.VITALIS_DB ?? join(ROOT, "vitalis.db"));
db.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA busy_timeout=3000; PRAGMA foreign_keys=ON;");

db.exec(`
CREATE TABLE IF NOT EXISTS tokens (
  id TEXT PRIMARY KEY, name TEXT NOT NULL, scope TEXT NOT NULL CHECK (scope IN ('ingest','read','write')),
  hash TEXT NOT NULL UNIQUE, prefix TEXT NOT NULL, created_at INTEGER NOT NULL, last_used_at INTEGER, revoked_at INTEGER);

-- Every push is kept as received (gzipped) before parsing, so a parser fix can be replayed over history.
CREATE TABLE IF NOT EXISTS payloads (
  id INTEGER PRIMARY KEY AUTOINCREMENT, received_at INTEGER NOT NULL, origin TEXT NOT NULL, sha256 TEXT NOT NULL UNIQUE,
  bytes INTEGER NOT NULL, body_gz BLOB NOT NULL, automation TEXT, aggregation TEXT, period TEXT,
  parsed_at INTEGER, counts TEXT, warnings TEXT, error TEXT);
CREATE INDEX IF NOT EXISTS payloads_received ON payloads(received_at);

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

-- Append-only record of every MCP call and push: who, what, outcome. Counts only, never values.
CREATE TABLE IF NOT EXISTS calls (
  id INTEGER PRIMARY KEY AUTOINCREMENT, at INTEGER NOT NULL, token_id TEXT, tool TEXT NOT NULL, ok INTEGER NOT NULL,
  ms INTEGER NOT NULL, detail TEXT);
CREATE INDEX IF NOT EXISTS calls_at ON calls(at);
`);

export const run = (sql: string, ...p: SQLInputValue[]) => db.prepare(sql).run(...p);
export const one = <T>(sql: string, ...p: SQLInputValue[]) => db.prepare(sql).get(...p) as T | undefined;
export const all = <T>(sql: string, ...p: SQLInputValue[]) => db.prepare(sql).all(...p) as T[];
export const marks = (n: number) => Array(n).fill("?").join(",");

export function tx<T>(fn: () => T): T {
  db.exec("BEGIN IMMEDIATE");
  try { const r = fn(); db.exec("COMMIT"); return r; } catch (e) { db.exec("ROLLBACK"); throw e; }
}
