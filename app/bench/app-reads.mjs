// App read routes (/v2/today, /v2/training, /v2/food/day) on one synthetic year. Target (spec 12 §3): p95 < 50 ms.
// Synthetic values only: a Health Auto Export year, native step and overnight HRV samples, food and strength sets.
import { writeFileSync } from 'node:fs';
const DAYS = 365, ROUNDS = Number(process.env.READ_ROUNDS ?? 100);
const pad = (n) => String(n).padStart(2, '0');
const addDays = (day, n) => { const d = new Date(`${day}T00:00:00Z`); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };

export async function run(app, createToken) {
  const { one, run: sql, tx } = await import('../dist/src/db.js');
  const { today } = await import('../dist/src/time.js');
  const { logSets } = await import('../dist/src/training.js');
  const token = createToken('app read probe', 'write').token, headers = { authorization: `Bearer ${token}`, 'content-type': 'application/json' };
  const end = today(), start = addDays(end, -(DAYS - 1));
  if (!one('SELECT 1 FROM sleep_nights LIMIT 1')) {
    const t0 = performance.now();
    const at = (d, hm) => `${d} ${hm}:00 +0530`, days = Array.from({ length: DAYS }, (_, i) => [i, addDays(start, i)]);
    const m = (name, units, row) => ({ name, units, data: days.map(([i, d]) => row(i, d)) });
    const hae = { data: { workouts: [], metrics: [
      m('resting_heart_rate', 'count/min', (i, d) => ({ date: at(d, '00:00'), qty: 58 + (i % 5), source: 'Synthetic Watch' })),
      m('heart_rate_variability', 'ms', (i, d) => ({ date: at(d, '00:00'), qty: 45 + (i % 11), source: 'Synthetic Watch' })),
      m('step_count', 'count', (i, d) => ({ date: at(d, '00:00'), qty: 6000 + (i % 9) * 500, source: '' })),
      m('active_energy', 'kcal', (i, d) => ({ date: at(d, '00:00'), qty: 400 + (i % 7) * 30, source: '' })),
      m('weight_body_mass', 'kg', (i, d) => ({ date: at(d, '00:00'), qty: 78 - i * 0.005, source: 'Synthetic Scale' })),
      m('sleep_analysis', 'hr', (i, d) => ({ date: at(d, '00:00'), source: 'Synthetic Watch', sleepStart: at(addDays(d, -1), '23:20'), sleepEnd: at(d, '06:50'),
        inBedStart: at(addDays(d, -1), '23:10'), inBedEnd: at(d, '07:00'), core: 4.2, deep: 1.1, rem: 1.7, awake: 0.3, totalSleep: 0, inBed: 0, asleep: 0 })),
    ] } };
    let r = await app.request('/ingest', { method: 'POST', headers, body: JSON.stringify(hae) }); if (!r.ok) throw Error(await r.text());
    const src = { name: 'Synthetic Watch', bundle_id: 'synthetic', version: '1', os_version: '26' }, samples = [];
    for (const [, d] of days) {
      for (let h = 7; h < 22; h++) samples.push({ uuid: `st-${d}-${h}`, type: 'HKQuantityTypeIdentifierStepCount', kind: 'quantity', start: `${d}T${pad(h)}:00:00.000+05:30`, end: `${d}T${pad(h)}:30:00.000+05:30`, source: src, value: 300 + h * 10, unit: 'count' },
        { uuid: `ae-${d}-${h}`, type: 'HKQuantityTypeIdentifierActiveEnergyBurned', kind: 'quantity', start: `${d}T${pad(h)}:00:00.000+05:30`, end: `${d}T${pad(h)}:30:00.000+05:30`, source: src, value: 25, unit: 'kcal' });
      for (let h = 0; h < 6; h++) samples.push({ uuid: `hv-${d}-${h}`, type: 'HKQuantityTypeIdentifierHeartRateVariabilitySDNN', kind: 'quantity', start: `${d}T${pad(h)}:10:00.000+05:30`, end: `${d}T${pad(h)}:10:00.000+05:30`, source: src, value: 40 + h * 3, unit: 'ms' });
    }
    for (let i = 0; i < samples.length; i += 5000) {
      r = await app.request('/v2/samples', { method: 'POST', headers, body: JSON.stringify({ schema: 1, batch_id: `app-read-${i}`, client: { install_id: 'synthetic', app_version: '1', os: 'iOS', model: 'iPhone' },
        upserts: samples.slice(i, i + 5000), deletions: [], daily_stats: [] }) });
      if (!r.ok) throw Error(await r.text());
    }
    tx(() => { for (const [i, d] of days) for (const [k, slot, hm, kcal] of [[0, 'breakfast', '08:10', 450], [1, 'lunch', '13:05', 700], [2, 'dinner', '20:30', 800]])
      sql(`INSERT INTO food_entries(id,meal_id,day,slot,eaten_at,tz_offset_min,name,kcal,protein_g,source,created_at,updated_at) VALUES(?,?,?,?,?,330,?,?,?,'manual',1,1)`,
        `f-${d}-${k}`, `m-${d}-${k}`, d, slot, Date.parse(`${d}T${hm}:00+05:30`), `Meal ${k}`, kcal + (i % 5) * 20, 35); });
    const lifts = [['legs', ['barbell-squat', 'romanian-deadlift', 'leg-press']], ['push', ['barbell-bench-press-medium-grip', 'standing-military-press', 'triceps-pushdown']], ['pull', ['wide-grip-lat-pulldown', 'bent-over-barbell-row', 'barbell-curl']]];
    for (const [i, d] of days) if (i % 2 === 0) {
      const [title, ex] = lifts[(i / 2) % 3];
      logSets({ title, sets: ex.flatMap((e, j) => Array.from({ length: 4 }, (_, k) => ({ id: `s-${d}-${j}-${k}`, exercise: e, weight_kg: 60 + (i % 20), reps: 8, performed_at: `${d}T18:${pad(j * 12 + k * 2)}:00+05:30` }))) }, 'bench');
    }
    console.error(`seeded ${DAYS} days in ${Math.round(performance.now() - t0)} ms`);
  }
  const routes = ['/v2/today', '/v2/training', '/v2/food/day', '/v2/sleep', '/v2/body'], report = {};
  for (const path of routes) {
    const times = [];
    for (let i = 0; i <= ROUNDS; i++) {
      const t = performance.now(), r = await app.request(path, { headers }); await r.text();
      if (!r.ok) throw Error(`${path} ${r.status}`);
      times.push(performance.now() - t);
    }
    const first = times.shift(), s = [...times].sort((a, b) => a - b), q = (p) => s[Math.min(s.length - 1, Math.ceil(p * s.length) - 1)];
    report[path] = { first_ms: +first.toFixed(1), p50_ms: +q(0.5).toFixed(1), p95_ms: +q(0.95).toFixed(1), max_ms: +s.at(-1).toFixed(1), n: s.length };
  }
  report.meta = { days: DAYS, rounds: ROUNDS, node: process.version, note: 'no If-None-Match: every request computes its body; first_ms includes filling the per-day cache' };
  console.log(JSON.stringify(report, null, 2));
  writeFileSync(process.env.READ_OUTPUT ?? 'bench/results/read-latency-app.json', JSON.stringify(report, null, 2) + '\n');
}
