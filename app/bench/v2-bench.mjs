// Deterministic synthetic data only. Full run: BENCH_LABEL=baseline npm run bench.
// BENCH_BATCHES lowers iteration count for development; published results always use >= 1M.
import { mkdtempSync, writeFileSync, statSync } from 'node:fs';
import { tmpdir, cpus } from 'node:os';
import { join } from 'node:path';
import { spawn, execFileSync } from 'node:child_process';
import { performance } from 'node:perf_hooks';
import * as zlib from 'node:zlib';

const dir = mkdtempSync(join(tmpdir(), 'vitalis-bench-'));
process.env.VITALIS_ROOT = dir;
process.env.VITALIS_DB = join(dir, 'bench.db');
process.env.VITALIS_TZ = 'UTC';
const { app } = await import('../dist/src/server.js');
const { db, all, one } = await import('../dist/src/db.js');
const { createToken } = await import('../dist/src/tokens.js');
const token = createToken('synthetic benchmark', 'write').token;
const headers = { authorization: `Bearer ${token}`, 'content-type': 'application/json' };
const N = 5000, DAY = 86400000, origin = Date.parse('2020-01-01T00:00:00Z');
const source = [
  { name: 'Benchmark Watch', bundle_id: 'com.apple.health', version: '26.1', product_type: 'Watch7,1', os_version: '26.1' },
  { name: 'Benchmark iPhone', bundle_id: 'com.apple.health', version: '26.1', product_type: 'iPhone17,1', os_version: '26.1' },
];
const device = { name: 'Synthetic device', manufacturer: 'Apple', model: 'Watch', hardware_version: '7', software_version: '26.1' };
let seq = 0, batchSeq = 0;
const uuid = () => `00000000-0000-4000-8000-${(++seq).toString(16).padStart(12, '0')}`;
const iso = ms => new Date(ms).toISOString();
const type = t => `HKQuantityTypeIdentifier${t}`;
const base = (t, i, ms, duration = 0) => ({ uuid: uuid(), type: t, start: iso(ms), end: iso(ms + duration),
  source: source[i % 2], device, metadata: {} });
const quantity = (i, ms, cumulative = false) => ({ ...base(type(cumulative ? (i % 2 ? 'ActiveEnergyBurned' : 'StepCount') : 'HeartRate'), Math.floor(i / 2), ms, cumulative ? 60000 : 0),
  kind: 'quantity', value: cumulative ? (i % 2 ? 0.7 + i % 9 / 10 : 20 + i % 70) : 55 + i % 55,
  unit: cumulative ? (i % 2 ? 'kcal' : 'count') : 'count/min' });
const workout = (i, ms, run = false) => ({ ...base('HKWorkoutTypeIdentifier', i, ms, run ? 2700000 : 3600000), kind: 'workout',
  activity_type: run ? 37 : 50, activity_name: run ? 'running' : 'traditionalStrengthTraining', duration_s: run ? 2700 : 3600,
  events: [], activities: [], statistics: { [type('HeartRate')]: { min: 80, avg: 125, max: 170, unit: 'count/min' },
    [type('ActiveEnergyBurned')]: { sum: 350, unit: 'kcal' }, ...(run ? { [type('DistanceWalkingRunning')]: { sum: 8000, unit: 'm' } } : {}) } });
let hrIndex = 0, cumulativeIndex = 0, sleepIndex = 0;
function generate(kind, n = N) {
  const out = [];
  for (let i = 0; i < n; i++) {
    if (kind === 'sleep') {
      const k = sleepIndex++, night = Math.floor(k / 25), stage = k % 25, ms = origin + night * DAY + 22 * 3600000 + stage * 20 * 60000;
      const value = [3, 3, 4, 3, 5, 2, 3][stage % 7];
      out.push({ ...base('HKCategoryTypeIdentifierSleepAnalysis', 0, ms, 20 * 60000), kind: 'category', value, value_label: ['inBed', 'asleepUnspecified', 'awake', 'asleepCore', 'asleepDeep', 'asleepREM'][value] });
    } else if (kind === 'cumulative') {
      const k = cumulativeIndex++; out.push(quantity(k, origin + Math.floor(k / 4) * 15 * 60000, true));
    } else if (kind === 'strength' && i < 100) {
      out.push(workout(i, origin + (1400 + i) * DAY + 17 * 3600000));
    } else if (kind === 'routes' && i < 20) {
      const ms = origin + (1450 + Math.floor(i / 2)) * DAY + 7 * 3600000;
      if (i % 2 === 0) out.push(workout(i, ms, true));
      else out.push({ ...base('HKWorkoutRoute', i, ms, 2700000), kind: 'route', workout_uuid: out.at(-1).uuid,
        points: Array.from({ length: 2700 }, (_, p) => [iso(ms + p * 1000), 37.7 + p * 0.00001, -122.4 + Math.sin(p / 20) * 0.001, 10 + Math.sin(p / 10), 3, 4, 3, 90]) });
    } else if (kind === 'cardiac' && i < 51) {
      const ms = origin + (1500 + i) * DAY;
      out.push(i === 50 ? { ...base('HKElectrocardiogramType', i, ms, 30000), kind: 'ecg', classification: 1, symptoms_status: 0, avg_hr: 68,
        sampling_hz: 512, voltages_uv: Array.from({ length: 15000 }, (_, p) => 120 * Math.sin(p / 13) + 5 * Math.sin(p / 3)) }
        : { ...base('HKHeartbeatSeriesSample', i, ms, 600000), kind: 'heartbeat', beats: Array.from({ length: 600 }, (_, p) => [p * 0.85, p % 117 === 0]) });
    } else {
      const k = hrIndex++, s = quantity(k, origin + k * 300000);
      if ((kind === 'heart_rate' || kind === 'strength') && i % 500 === 499) {
        s.end = iso(Date.parse(s.start) + 60000);
        s.series = Array.from({ length: 60 }, (_, p) => [iso(Date.parse(s.start) + p * 1000), iso(Date.parse(s.start) + p * 1000), 100 + p % 60]);
      }
      out.push(s);
    }
  }
  return out;
}
const envelope = (upserts = [], deletions = []) => ({ schema: 1, batch_id: `bench-${++batchSeq}`, client: { install_id: 'synthetic', app_version: '1', os: 'iOS 26.1', model: 'iPhone17,1' }, upserts, deletions, daily_stats: [] });
const tick = () => new Promise(resolve => setImmediate(resolve));
const summary = xs => { const s = [...xs].sort((a, b) => a - b); return { p50_ms: s[Math.floor((s.length - 1) * .50)], p95_ms: s[Math.ceil((s.length - 1) * .95)], max_ms: s.at(-1) }; };
const timings = {}, counts = {}, profiles = [];
let longestBlock = 0, last = performance.now(), monitoring = false;
const monitor = setInterval(() => { const t = performance.now(); if (monitoring) longestBlock = Math.max(longestBlock, t - last); last = t; }, 1);
async function ingest(b, kind) {
  const raw = JSON.stringify(b); // wire body generation is outside the timed request
  if (Buffer.byteLength(raw) > 50 * 1048576) throw new Error('benchmark exceeds wire limit');
  await tick(); last = performance.now(); monitoring = true;
  const t = performance.now();
  const r = await app.request('/v2/samples', { method: 'POST', headers, body: raw });
  const data = await r.json();
  const ms = performance.now() - t;
  await new Promise(resolve => setTimeout(resolve, 2)); monitoring = false;
  if (r.status !== 200 || data.counts.rejected) throw new Error(JSON.stringify({ status: r.status, data }));
  (timings[kind] ??= []).push(ms); counts[kind] = (counts[kind] ?? 0) + b.upserts.length + b.deletions.length;
  return data;
}
console.log(`Synthetic DB: ${process.env.VITALIS_DB}`);
const batches = Number(process.env.BENCH_BATCHES ?? 201);
let deletionSamples;
for (let i = 0; i < batches; i++) {
  const kind = i < 115 ? 'heart_rate' : i < 190 ? 'cumulative' : i < 198 ? 'sleep' : ['strength', 'routes', 'cardiac'][i - 198];
  const samples = generate(kind);
  if (i === 0) deletionSamples = samples;
  await ingest(envelope(samples), kind);
  if (i % 20 === 0 || i === batches - 1) console.log(`${(i + 1) * N} samples: ${kind} ${timings[kind].at(-1).toFixed(1)} ms`);
}
await ingest(envelope([], deletionSamples.map(({ uuid, type }) => ({ uuid, type }))), 'deletions');
await ingest(envelope(deletionSamples), 'reupserts');
for (let i = 0; i < 20; i++) await ingest(envelope(generate('heart_rate', 100)), 'steady_state');

// Read scheduled in the same event-loop turn as a 5K ingest. Includes queueing behind any synchronous work.
let readDuring;
const concurrent = envelope(generate('cumulative'));
const tRead = performance.now();
const readPromise = new Promise((resolve, reject) => setTimeout(async () => {
  try { const r = await app.request('/health'); if (r.status !== 200) throw new Error('health'); readDuring = performance.now() - tRead; resolve(); } catch (e) { reject(e); }
}, 1));
await Promise.all([ingest(concurrent, 'concurrent_cumulative'), readPromise]);

const readSpecs = {
  status: ['/v2/sync/status'],
  freshness: ['get_freshness', {}],
  metrics_90d: ['get_metrics', { metrics: ['heart_rate', 'steps', 'active_kcal'], from: '2021-01-01', to: '2021-03-31' }],
  sleep_30n: ['get_sleep', { from: '2024-03-01', to: '2024-03-30' }],
  list_workouts: ['list_workouts', { from: '2023-10-01', to: '2024-03-30' }],
};
let callId = 0;
async function read(spec) {
  const r = spec.length === 1 ? await app.request(spec[0], { headers }) : await app.request('/mcp', { method: 'POST',
    headers: { ...headers, accept: 'application/json, text/event-stream', 'mcp-protocol-version': '2025-06-18' },
    body: JSON.stringify({ jsonrpc: '2.0', id: ++callId, method: 'tools/call', params: { name: spec[0], arguments: spec[1] } }) });
  const text = await r.text(); if (r.status !== 200 || text.includes('"isError":true')) throw new Error(text);
}
const reads = {};
for (const [name, spec] of Object.entries(readSpecs)) {
  await read(spec);
  const times = [];
  for (let i = 0; i < 12; i++) { const t = performance.now(); await read(spec); times.push(performance.now() - t); }
  reads[name] = summary(times);
}
clearInterval(monitor);
db.exec('PRAGMA wal_checkpoint(TRUNCATE)');
let tables = {};
try { tables = Object.fromEntries(all('SELECT name,SUM(pgsize) bytes FROM dbstat GROUP BY name').map(r => [r.name, r.bytes])); } catch {
  // Node SQLite builds without dbstat: VACUUM INTO produces a compact clone, then subtract grouped table drops.
  const { DatabaseSync } = await import('node:sqlite');
  const clonePath = join(dir, 'size.db'); db.exec(`VACUUM INTO '${clonePath}'`);
  const clone = new DatabaseSync(clonePath); clone.exec('PRAGMA foreign_keys=OFF');
  for (const group of [ ['samples', ['hk_samples', 'hk_tombstones', 'hk_sample_values', 'hk_types', 'hk_sources', 'hk_devices']],
    ['points', ['hk_quantity_points', 'hk_route_points', 'hk_heartbeat_beats', 'hk_blobs']], ['payloads', ['payloads']] ]) {
    const before = statSync(clonePath).size;
    for (const table of group[1]) clone.exec(`DROP TABLE IF EXISTS ${table}`);
    clone.exec('VACUUM'); tables[group[0]] = before - statSync(clonePath).size;
  }
  clone.close();
}
const rawBodies = one("SELECT SUM(length(body_gz)) n FROM payloads WHERE origin='v2'").n;
const sampleCount = one('SELECT COUNT(*) n FROM hk_samples').n;
const sampleBytes = tables.samples ?? Object.entries(tables).filter(([k]) => /^hk_(samples|tombstones|sample_values|values|types|sources|devices|contributions)|^sqlite_autoindex_hk_(samples|tombstones|sample_values|types|sources|devices|contributions)/.test(k)).reduce((n, [, v]) => n + v, 0);
const pointBytes = tables.points ?? Object.entries(tables).filter(([k]) => /hk_(quantity_points|route_points|heartbeat_beats|blobs)/.test(k)).reduce((n, [, v]) => n + v, 0);
// Generator counts: 60 points per 500th HR object, ten 2700-point routes, 50 x 600 beats, one 15K ECG.
const pointCount = ['hk_quantity_points', 'hk_route_points', 'hk_heartbeat_beats'].reduce((n, table) => n + one(`SELECT COUNT(*) n FROM ${table}`).n, 0);
const compressionBody = Buffer.from(JSON.stringify(envelope(generate('cumulative'))));
const compression = {};
for (const [name, compress] of [['gzip', b => zlib.gzipSync(b)], ...(zlib.zstdCompressSync ? [['zstd', b => zlib.zstdCompressSync(b)]] : [])]) {
  const times = []; let compressed;
  for (let i = 0; i < 10; i++) { const t = performance.now(); compressed = compress(compressionBody); times.push(performance.now() - t); }
  compression[name] = { input_bytes: compressionBody.length, bytes: compressed.length, ...summary(times) };
}

async function coldStart(path) {
  const times = [];
  for (let i = 0; i < 3; i++) {
    const start = performance.now();
    const child = spawn(process.execPath, ['dist/src/server.js'], { env: { ...process.env, VITALIS_DB: path.endsWith('empty.db') ? join(dir, `empty-${i}.db`) : path, PORT: '0' }, stdio: ['ignore', 'pipe', 'pipe'] });
    let output = '', errors = '';
    child.stderr.on('data', s => { errors += s; });
    const port = await new Promise((resolve, reject) => {
      const timer = setTimeout(() => { child.kill(); reject(new Error('cold start timeout: ' + errors)); }, 30000);
      child.stdout.on('data', s => { output += s; const m = output.match(/listening on .*:(\d+)/); if (m) { clearTimeout(timer); resolve(m[1]); } });
      child.on('exit', code => { if (code) { clearTimeout(timer); reject(new Error(errors)); } });
    });
    const r = await fetch(`http://127.0.0.1:${port}/health`); await r.text(); if (!r.ok) throw new Error('cold health failed');
    times.push(performance.now() - start); child.kill(); await new Promise(resolve => child.on('exit', resolve));
  }
  return summary(times);
}
const cold = { empty: await coldStart(join(dir, 'empty.db')), million: await coldStart(process.env.VITALIS_DB) };
const report = { label: process.env.BENCH_LABEL ?? 'current', commit: execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim(),
  node: process.version, cpu: cpus()[0].model, generated_samples: batches * N, sample_count: sampleCount, batch_size: N,
  batches: Object.fromEntries(Object.entries(timings).map(([kind, times]) => [kind, { batches: times.length, objects: counts[kind], samples_per_second: counts[kind] / (times.reduce((a, b) => a + b, 0) / 1000), ...summary(times) }])),
  batch_wall: summary(Object.entries(timings).filter(([k]) => k !== 'steady_state').flatMap(([, v]) => v)), longest_event_loop_block_ms: longestBlock,
  read_during_ingest_ms: readDuring, reads, cold_start: cold,
  storage: { checkpoint_bytes: statSync(process.env.VITALIS_DB).size, sample_bytes: sampleBytes, bytes_per_sample: sampleBytes / sampleCount,
    point_bytes: pointBytes, generated_points: pointCount, bytes_per_point: pointBytes / pointCount, retained_payload_bytes: rawBodies,
    retained_payload_share: rawBodies / statSync(process.env.VITALIS_DB).size, tables }, compression, db_path: process.env.VITALIS_DB };
const path = process.env.BENCH_OUTPUT ?? `bench/results/${report.label}.json`;
writeFileSync(path, JSON.stringify(report, null, 2) + '\n');
console.log(JSON.stringify(report, null, 2));
console.log(`Report: ${path}`);
// Workers, when enabled, must not keep a CLI benchmark alive.
process.exit(0);
