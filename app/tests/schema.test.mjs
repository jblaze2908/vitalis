import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { all } from "./_env.mjs";
import { bumpDataVersion, bumpTargetsVersion, dataVersions } from "../dist/src/db.js";

const NEW_TABLES = ["meta", "targets", "kcal_targets", "daily_derived", "weight_entries", "food_entries", "saved_meals", "food_barcodes", "food_search_cache"];
const cols = (table) => all(`PRAGMA table_info(${table})`).map((c) => c.name);

const child = (root, script) => {
  const env = { ...process.env, VITALIS_ROOT: root }; delete env.VITALIS_DB;
  return spawnSync(process.execPath, ["--input-type=module", "-e", script], { encoding: "utf8", env });
};
const DUMP = `const { all } = await import('./dist/src/db.js');
  console.log(JSON.stringify({ schema: all("SELECT type,name,sql FROM sqlite_master ORDER BY name"), meta: all("SELECT key,value FROM meta ORDER BY key"),
    sleep: all("PRAGMA table_info(sleep_nights)").map(c => c.name), sessions: all("PRAGMA table_info(sessions)").map(c => c.name),
    nights: all("SELECT day,asleep_h,wakeups FROM sleep_nights"), rows: all("SELECT id,title,hk_workout_uuid,template,client_source FROM sessions") }));`;

test("a fresh database has every new table, column, index and meta row", () => {
  const tables = all("SELECT name FROM sqlite_master WHERE type='table'").map((r) => r.name);
  for (const t of NEW_TABLES) assert.ok(tables.includes(t), t);
  assert.ok(cols("sleep_nights").includes("wakeups"));
  for (const c of ["hk_workout_uuid", "template", "client_source"]) assert.ok(cols("sessions").includes(c), c);
  assert.ok(all("SELECT name FROM sqlite_master WHERE type='index'").some((r) => r.name === "sessions_hk"));
  assert.ok(tables.includes("sleep_naps"));
  // sleep_rules is written by resplitSleepOnce at server start; a fresh database runs it as a no-op.
  assert.deepEqual(all("SELECT key FROM meta ORDER BY key").map((r) => r.key), ["data_version", "sleep_rules", "targets_version"]);
});

test("version helpers bump each counter independently", () => {
  const before = dataVersions();
  bumpDataVersion(); bumpDataVersion(); bumpTargetsVersion();
  assert.deepEqual(dataVersions(), { data: before.data + 2, targets: before.targets + 1 });
});

test("a database created by the previous code upgrades in place, and a second start is a no-op", () => {
  const root = mkdtempSync(join(tmpdir(), "vitalis-schema-"));
  const old = new DatabaseSync(join(root, "vitalis.db"));
  // Pre-change DDL of the two tables that gain columns (d3ca9ab).
  old.exec(`CREATE TABLE sleep_nights (
      day TEXT NOT NULL, source TEXT NOT NULL, sleep_start TEXT, sleep_end TEXT, in_bed_start TEXT, in_bed_end TEXT,
      asleep_h REAL NOT NULL, core_h REAL, deep_h REAL, rem_h REAL, awake_h REAL, payload_id INTEGER, updated_at INTEGER NOT NULL,
      PRIMARY KEY (day, source));
    CREATE TABLE sessions (
      id TEXT PRIMARY KEY, title TEXT, started_at INTEGER NOT NULL, ended_at INTEGER, tz_offset_min INTEGER NOT NULL,
      notes TEXT, source TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, deleted_at INTEGER);
    INSERT INTO sleep_nights(day,source,asleep_h,updated_at) VALUES('2026-10-01','Old Watch',7.5,1);
    INSERT INTO sessions(id,title,started_at,tz_offset_min,source,created_at,updated_at) VALUES('s1','Push',1,330,'mcp:x',1,1);`);
  old.close();

  const first = child(root, DUMP);
  assert.equal(first.status, 0, first.stderr);
  const a = JSON.parse(first.stdout.trim());
  assert.ok(a.sleep.includes("wakeups"));
  for (const c of ["hk_workout_uuid", "template", "client_source"]) assert.ok(a.sessions.includes(c), c);
  assert.deepEqual(a.meta, [{ key: "data_version", value: 0 }, { key: "targets_version", value: 0 }]);
  assert.deepEqual(a.nights, [{ day: "2026-10-01", asleep_h: 7.5, wakeups: null }]);
  assert.deepEqual(a.rows, [{ id: "s1", title: "Push", hk_workout_uuid: null, template: null, client_source: null }]);
  for (const t of NEW_TABLES) assert.ok(a.schema.some((s) => s.name === t), t);

  const second = child(root, DUMP);
  assert.equal(second.status, 0, second.stderr);
  assert.deepEqual(JSON.parse(second.stdout.trim()), a);
});
