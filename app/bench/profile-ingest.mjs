// Run with node --cpu-prof --cpu-prof-dir=.data/profiles bench/profile-ingest.mjs.
// The same ingest implementation executes synchronously here so the CPU profile includes its entire stack.
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
mkdirSync('.data/profiles', { recursive: true });
const root = mkdtempSync('.data/profiles/ingest-');
process.env.VITALIS_ROOT = root;
process.env.VITALIS_DB = process.env.PROFILE_DB ?? `${root}/profile.db`;
process.env.VITALIS_PROFILE = `${root}/phases.jsonl`;
const { ingestV2 } = await import('../dist/src/v2.js');
const { one } = await import('../dist/src/db.js');
const initialSamples = one('SELECT COUNT(*) n FROM hk_samples').n;
const batches = Number(process.env.PROFILE_BATCHES ?? 20), quantityType = process.env.PROFILE_TYPE ?? 'HeartRate';
const source = { name: 'Profile Watch', bundle_id: 'com.apple.health', version: '26.1', product_type: 'Watch7,1', os_version: '26.1' };
const device = { name: 'Synthetic device', manufacturer: 'Apple', model: 'Watch', hardware_version: '7', software_version: '26.1' };
let seq = 0; const seed = Date.now() >>> 0;
for (let batch = 0; batch < batches; batch++) {
  const upserts = Array.from({ length: 5000 }, (_, i) => {
    const n = ++seq, t = new Date(1577836800000 + n * 300000).toISOString();
    return { uuid: `${(Math.imul((n ^ seed) >>> 0,2654435761)>>>0).toString(16).padStart(8,'0')}-0000-4000-8000-${n.toString(16).padStart(12,'0')}`, type: `HKQuantityTypeIdentifier${quantityType}`, kind: 'quantity',
      start: t, end: t, ...(process.env.PROFILE_TZ ? { tz: process.env.PROFILE_TZ } : {}), source, device, metadata: {}, value: 55 + i % 55, unit: quantityType === 'HeartRate' ? 'count/min' : 'count' };
  });
  const raw = Buffer.from(JSON.stringify({ schema: 1, batch_id: `profile-${Date.now()}-${batch}`, client: { install_id: 'synthetic', app_version: '1', os: 'iOS 26.1', model: 'iPhone17,1' }, upserts, deletions: [], daily_stats: [] }));
  const result = ingestV2(raw); if (result.counts.rejected) throw new Error(JSON.stringify(result));
}
const rows = readFileSync(process.env.VITALIS_PROFILE, 'utf8').trim().split('\n').map(JSON.parse).slice(3);
const summary = Object.fromEntries(Object.keys(rows[0]).map(key => [key, rows.reduce((n,r)=>n+r[key],0)/rows.length]));
summary.scalar_samples_per_second = 5000000 / summary.wall_ms;
const report = { batches, warmup_batches: 3, initial_sample_count: initialSamples, final_sample_count: one('SELECT COUNT(*) n FROM hk_samples').n, average: summary, phases_path: process.env.VITALIS_PROFILE, db_path: process.env.VITALIS_DB };
writeFileSync(process.env.PROFILE_OUTPUT ?? 'bench/results/profile.json', JSON.stringify(report,null,2)+'\n');
console.log(JSON.stringify(report,null,2));
