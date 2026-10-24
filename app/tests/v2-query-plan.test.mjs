import { test } from 'node:test';
import assert from 'node:assert/strict';
import { all } from './_env.mjs';
import { METRIC_AGGREGATE_SQL } from '../dist/src/v2-derived.js';

test('touched metric aggregates seek each day/source instead of scanning the raw ledger', () => {
  const plan = all('EXPLAIN QUERY PLAN ' + METRIC_AGGREGATE_SQL, JSON.stringify([{ metric: 'heart_rate', day: '2020-12-01', source: 'Watch' }]));
  assert.ok(plan.some(r => /SEARCH s USING INDEX hk_samples_day \(type_id=\? AND day=\? AND source_id=\?\)/.test(r.detail)), JSON.stringify(plan));
  assert.ok(plan.some(r => /SEARCH v USING INDEX hk_value_days_day \(day=\?\)/.test(r.detail)), JSON.stringify(plan));
  assert.ok(!plan.some(r => /^SCAN s\b/.test(r.detail)), JSON.stringify(plan));
});
