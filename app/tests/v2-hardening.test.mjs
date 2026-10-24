// Production-review fixes: batch caps, one ingest writer, old-layout migration and hk_types mapping sync.
import { test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { spawnSync } from "node:child_process";
import { gzipSync } from "node:zlib";
import { all, body, http, one, payload, tokens } from "./_env.mjs";

const ingestToken = tokens.createToken("native phone", "ingest").token;
const hae = tokens.createToken("hae phone", "ingest").token;
const type = (s) => `HKQuantityTypeIdentifier${s}`;
const batch = (upserts = [], props = {}) => ({ schema: 1, batch_id: randomUUID(), client: { install_id: "test", app_version: "0.1", os: "iOS 26", model: "Test" },
  upserts, deletions: [], daily_stats: [], ...props });
const post = (b) => http("POST", "/v2/samples", { token: ingestToken, json: b });
const steps = (i) => ({ uuid: randomUUID(), type: type("StepCount"), kind: "quantity", start: `2026-09-${String(1 + (i % 28)).padStart(2, "0")}T10:00:00.000+05:30`,
  end: `2026-09-${String(1 + (i % 28)).padStart(2, "0")}T10:05:00.000+05:30`, source: { name: "Native Watch", bundle_id: "com.apple.health" }, value: 10 + i, unit: "count" });
const deletion = () => ({ uuid: randomUUID(), type: type("StepCount") });
const payloadCount = () => one("SELECT COUNT(*) n FROM payloads").n;
const batchCount = () => one("SELECT COUNT(*) n FROM hk_batches").n;

test("a batch over 5,000 upserts + deletions is refused with 413 before anything is applied or retained", async () => {
  const before = [payloadCount(), batchCount()];
  const over = await post(batch(Array.from({ length: 2500 }, () => ({})), { deletions: Array.from({ length: 2501 }, deletion) }));
  assert.equal(over.status, 413, over.text);
  assert.match(over.json.error, /5001 upserts \+ deletions; the limit is 5000/);
  assert.deepEqual([payloadCount(), batchCount()], before, "no payload row and no batch record");
  assert.equal(one("SELECT COUNT(*) n FROM hk_tombstones").n, 0);
  const exact = await post(batch([], { deletions: Array.from({ length: 5000 }, deletion) }));
  assert.equal(exact.status, 200, exact.text);
  assert.equal(exact.json.counts.deleted, 5000);
});

test("a batch over 5,000 daily_stats is refused with 413; 5,000 is accepted", async () => {
  const before = [payloadCount(), batchCount()];
  const over = await post(batch([], { daily_stats: Array.from({ length: 5001 }, () => ({})) }));
  assert.equal(over.status, 413, over.text);
  assert.match(over.json.error, /5001 daily_stats; the limit is 5000/);
  assert.deepEqual([payloadCount(), batchCount()], before);
  const exact = await post(batch([], { daily_stats: Array.from({ length: 5000 }, () => ({})) }));
  assert.equal(exact.status, 200, exact.text);
  assert.equal(exact.json.counts.rejected, 5000);
});

test("a maximum-size native batch and a concurrent /ingest both succeed through the one writer", async () => {
  const native = post(batch(Array.from({ length: 5000 }, (_, i) => steps(i))));
  const push = http("POST", "/ingest", { token: hae, raw: body(payload("2026-08-01", 3)) });
  const [n, h] = await Promise.all([native, push]);
  assert.equal(n.status, 200, n.text); assert.equal(n.json.counts.inserted, 5000);
  assert.equal(h.status, 200, h.text); assert.equal(h.json.duplicate, false);
  assert.equal(h.json.counts.metric_days > 0, true);
  assert.equal(one("SELECT COUNT(*) n FROM metric_days WHERE day='2026-08-01' AND metric='resting_hr'").n, 1);
  const dup = await http("POST", "/ingest", { token: hae, raw: body(payload("2026-08-01", 3)) });
  assert.equal(dup.json.duplicate, true);
  const bad = await http("POST", "/ingest", { token: hae, raw: "nope" });
  assert.equal(bad.status, 400); assert.match(bad.json.error, /not JSON/);
});

// Runs `script` in a child process with its own VITALIS_ROOT (cwd is the app directory).
const child = (root, script) => {
  const env = { ...process.env, VITALIS_ROOT: root }; delete env.VITALIS_DB;
  return spawnSync(process.execPath, ["--input-type=module", "-e", script], { encoding: "utf8", env });
};

test("a database from the dcfe6d3 v2 layout starts, keeps payloads, and reparse --all rebuilds the hk_* tables", async () => {
  const { mkdtempSync, readFileSync } = await import("node:fs");
  const { tmpdir } = await import("node:os");
  const { join } = await import("node:path");
  const { DatabaseSync } = await import("node:sqlite");
  const root = mkdtempSync(join(tmpdir(), "vitalis-old-layout-"));
  const old = new DatabaseSync(join(root, "vitalis.db"));
  old.exec(readFileSync(new URL("./fixtures/dcfe6d3-layout.sql", import.meta.url), "utf8"));
  const s = steps(0), b = batch([s]), raw = Buffer.from(JSON.stringify(b));
  old.prepare("INSERT INTO payloads(received_at,origin,sha256,bytes,body_gz,parsed_at) VALUES(1,'v2','sha-v2',?,?,1)").run(raw.length, gzipSync(raw));
  old.prepare("INSERT INTO payloads(received_at,origin,sha256,bytes,body_gz) VALUES(2,'rest:x','sha-hae',2,?)").run(gzipSync(Buffer.from("{}")));
  old.prepare(`INSERT INTO hk_samples(uuid,type,kind,start_ms,end_ms,start_iso,end_iso,source_name,source_bundle,source_json,extra_json,content_hash,payload_id,created_at,updated_at)
    VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`).run(s.uuid, s.type, "quantity", 1, 2, s.start, s.end, "Native Watch", "com.apple.health", "{}", "{}", "h", 1, 1, 1);
  old.prepare("INSERT INTO hk_batches(batch_id,payload_id,received_at,counts_json,rejected_json) VALUES('old',1,1,'{}','[]')").run();
  old.close();

  const start = child(root, `const { all } = await import('./dist/src/db.js');
    console.log(JSON.stringify({ cols: all('PRAGMA table_info(hk_samples)').map(c => c.name), batches: all('SELECT * FROM hk_batches'),
      payloads: all('SELECT id,origin,codec FROM payloads ORDER BY id'), old: all("SELECT name FROM sqlite_master WHERE name IN ('hk_quantity_points','hk_sample_values')") }));`);
  assert.equal(start.status, 0, start.stderr);
  assert.match(start.stderr, /dropped the old \(dcfe6d3\) hk_\* native layout.*vitalis reparse --all/);
  const r = JSON.parse(start.stdout.trim());
  assert.ok(r.cols.includes("type_id")); assert.deepEqual(r.batches, []); assert.deepEqual(r.old, []);
  assert.deepEqual(r.payloads, [{ id: 1, origin: "v2", codec: "gzip" }, { id: 2, origin: "rest:x", codec: "gzip" }]);

  const second = child(root, "await import('./dist/src/db.js');");
  assert.equal(second.status, 0, second.stderr); assert.equal(second.stderr.includes("dropped"), false, "only the first start migrates");

  const rebuilt = child(root, `import { spawnSync } from 'node:child_process';
    const cli = spawnSync(process.execPath, ['dist/src/cli.js', 'reparse', '--all'], { encoding: 'utf8' });
    const { one } = await import('./dist/src/db.js');
    console.log(JSON.stringify({ status: cli.status, out: cli.stdout, err: cli.stderr, raw: one('SELECT uuid,value FROM hk_raw WHERE uuid=?', ${JSON.stringify(s.uuid)}) }));`);
  assert.equal(rebuilt.status, 0, rebuilt.stderr);
  const out = JSON.parse(rebuilt.stdout.trim());
  assert.equal(out.raw.uuid, s.uuid); assert.equal(out.raw.value, s.value);
});

test("hk_types.metric and cumulative follow HK_METRICS at every start", async () => {
  const { mkdtempSync } = await import("node:fs");
  const { tmpdir } = await import("node:os");
  const { join } = await import("node:path");
  const root = mkdtempSync(join(tmpdir(), "vitalis-types-"));
  const seed = child(root, `const { run } = await import('./dist/src/db.js');
    run("INSERT INTO hk_types(identifier,metric,cumulative) VALUES('${type("StepCount")}','stale_metric',0)");
    run("INSERT INTO hk_types(identifier,metric,cumulative) VALUES('${type("HeartRate")}',NULL,1)");
    run("INSERT INTO hk_types(identifier,metric,cumulative) VALUES('${type("Unmapped")}','removed_mapping',1)");`);
  assert.equal(seed.status, 0, seed.stderr);
  const check = child(root, `const { all } = await import('./dist/src/db.js');
    console.log(JSON.stringify(all('SELECT identifier,metric,cumulative FROM hk_types ORDER BY identifier')));`);
  assert.equal(check.status, 0, check.stderr);
  assert.deepEqual(JSON.parse(check.stdout.trim()), [
    { identifier: type("HeartRate"), metric: "heart_rate", cumulative: 0 },
    { identifier: type("StepCount"), metric: "steps", cumulative: 1 },
    { identifier: type("Unmapped"), metric: null, cumulative: 0 }]);
});
