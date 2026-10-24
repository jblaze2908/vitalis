# Vitalis v2 ingest implementation and measurements

Measured 2026-10-24 on Intel(R) Core(TM) i5-8250U CPU @ 1.60GHz, Node v22.23.1, ext4 on this machine. Baseline runtime: `dcfe6d3530351ca3b6dc69530426970980399a18`. Final measured runtime: `0534f63949797c1eb27457d1623d8b9615dd23bb`.

The 50,000 scalar quantities/s target was not reached: cumulative quantities measured 8,777/s end to end. The ingest-window timer maximum was 18.08 ms against the 20 ms goal (observed goal met).

All work is committed on `feat/native-sync`. Nothing was pushed or merged; main and vitalis-apple were not touched. Required typecheck, build and all 63 tests pass. No Rust was written.

## Review findings

| Finding | Implementation | Regression in app/tests/v2.test.mjs unless noted |
| --- | --- | --- |
| 1. Workout HR/distance | Workout HR statistics first; the first present Distance* statistic converts to km. Otherwise prefer matching name+bundle HR points, then all sources. HR arrivals/replacements/deletions refresh overlapping workouts. | workout statistics win; cycling distance converts; fallback HR refreshes across sources |
| 2. Source selection | Merged source '' wins; mapped cumulative metrics use the largest qty. Discrete metrics retain Watch ranking and a lexical tie-break, including HAE discrete values stored in qty. | source selection prefers merged rows, largest cumulative qty, and deterministic discrete ties; discrete HAE qty rows keep Watch ranking and deterministic ties |
| 3. Sleep unknown stages | No staged segments means NULL core/deep/REM; once staged data exists, missing stages are zero. No awake segments means NULL awake. | unstaged sleep and unobserved awake remain null, while observed staged absences are zero |
| 4. Reused batch ID | Compare the stored decoded-payload SHA-256 and return 409 for different bytes; retain the failed attempt without applying it. | a reused batch id with different bytes returns 409 and applies no objects |
| 5. Sleep wake day | Choose wake day/end from asleep members, falling back to all members only for sessions without asleep data. | sleep wake day follows asleep end even when in-bed/awake extends across the next midnight |
| 6. Sync-status scan | Maintain per-type live/deleted/newest counters transactionally; status reads only the small counter table and last 20 batches. | status counters track type replacement, newest deletion, unknown tombstones and late upserts once; transaction rollback test also checks counters |
| 7. Sleep interval scan | Maintain a conservative maximum duration and bound both start-time sides. The category/source/start index range-seeks while retaining long enclosing intervals. | sleep range is bounded on both sides and preserves long enclosing segments |
| 8. Tombstones | Delete blobs and day-summary children; clear scalar/metadata/extra content. Late upserts persist identity/deleted/audit state and content hash only. Raw payload retention remains intact. | tombstones clear every child and ECG content, including deletion-before-upsert and re-upsert |

Deliberate `pickPerDay` change: with two non-merged sources for a cumulative metric, the largest total now wins; before, it picked by source-name order.

The source-selection regressions are in `app/tests/stats.test.mjs`. Additional regressions cover exact binary round trips, UUID kind replacement, weighted series means, malformed primitive daily stats, worker read responsiveness under a write lock, negative-zero ISO offsets, series points outside parent intervals, and newer unchanged acceptances protecting against older replay. `v2-query-plan.test.mjs` checks the actual touched-day aggregate plan.

## Final schema

- `hk_samples`: INTEGER rowid, exact case-sensitive UUID unique index, small dictionary references for type/source/device, integer kinds, millisecond start/end plus offsets/format bytes, 32-byte hashes, and one nullable metadata/extra JSON column. Unknown fields and units remain available; original raw bodies remain replayable.
- `hk_blobs`: one lossless Float64 binary blob per quantity series, route, heartbeat series or ECG. Point bounds are indexed for partial workout HR reads. Layout and timestamp exceptions are documented in [v2-storage.md](v2-storage.md).
- Ordinary scalar samples aggregate from their indexed raw day/value. `hk_value_days` contains only series/day summaries and midnight splits; the former per-point `hk_sample_values` projection is gone. Final summary tables/indexes use only 0.07 MiB.
- `hk_tombstones`, `hk_type_status`, `hk_sleep_bounds`, membership, daily stats and batch tables preserve permanent deletion/idempotency and support bounded reads. Existing `metric_days`, `sleep_nights` and `hk_workouts` keep their MCP interfaces.
- Existing non-v2 tables retain their schema/semantics; only `payloads.codec DEFAULT 'gzip'` is added. Existing production-format startup and legacy ingest/replay regressions pass. There is no migration from the undeployed original v2 layout.

WAL and synchronous=NORMAL remain. Measured defaults: 4 KiB pages on fresh DBs, 64 MiB cache per connection, 256 MiB mmap ceiling, memory temp storage, and 8,192-page checkpoints. Existing files keep their page size. HTTP ingest and gzip/parse/validation/compression/projections run in a worker with its own DatabaseSync connection. Contended token-use/call-audit writes retry without waiting on a SQLite writer lock.

## Before/after: every workload

Each main run starts with a fresh disk DB and inserts 1,005,000 parents in 201 x 5,000-object batches, then performs deletion/re-upsert, small-batch and concurrent-read probes (1,012,000 stored parents at the main measurement). Daily statistics accompany affected quantity days. See [the harness methodology](../app/bench/README.md) and [raw reports](../app/bench/results/).

Rates count parent operations; route/cardiac/strength batches mix bulky objects with scalar HR to fit the existing body limit. Steady-state uses 100 parents. Special shapes/deletions/re-upserts have one observation each, so their p50/p95 are the same observation; scalar HR/cumulative have 115/75 batches, sleep eight. Percentiles are observed nearest-rank.

| 5K parent workload | Baseline objects/s | Final objects/s | Baseline wall p50 / p95 ms | Final wall p50 / p95 ms |
| --- | --- | --- | --- | --- |
| Heart rate + dense series | 2,627 | 11,091 | 1,925.27 / 2,052.73 | 380.10 / 678.08 |
| Steps + active energy | 2,402 | 8,777 | 2,076.81 / 2,137.72 | 458.27 / 757.56 |
| Sleep stages | 1,554 | 3,333 | 3,129.76 / 3,577.62 | 1,359.92 / 1,789.67 |
| Strength + HR | 2,246 | 5,903 | 2,226.31 / 2,226.31 | 847.00 / 847.00 |
| Runs/routes + HR | 2,017 | 7,751 | 2,479.36 / 2,479.36 | 645.10 / 645.10 |
| Heartbeats/ECG + HR | 2,000 | 5,758 | 2,500.11 / 2,500.11 | 868.31 / 868.31 |
| Deletions | 5,211 | 13,104 | 959.45 / 959.45 | 381.55 / 381.55 |
| Tombstoned re-upserts | 12,249 | 16,956 | 408.21 / 408.21 | 294.88 / 294.88 |
| 100-object steady state | 1,918 | 5,350 | 37.66 / 89.66 | 17.34 / 30.67 |
| Cumulative + overlapping read | 2,117 | 6,671 | 2,361.76 / 2,361.76 | 749.47 / 749.47 |

## Latency at 1M parents

Hot reads use actual authenticated HTTP/MCP tools with 12 measured observations after warmup. Cold start measures process spawn until a real HTTP /health response, with three fresh processes per shape; OS caches are not flushed. Timer intervals include GC and scheduler delays and bound synchronous stalls; fixture construction/stringification is outside request timing.

| Metric | dcfe6d3 | Final |
| --- | --- | --- |
| 5K batch wall p50 / p95 (ms) | 2,020.53 / 2,479.36 | 411.85 / 769.63 |
| Longest 5K batch wall | 3,577.62 ms | 1,789.67 ms |
| Longest observed ingest-window event-loop interval | 3,577.66 ms | 18.08 ms |
| Health read issued during 5K ingest | 2,373.58 ms | 16.62 ms |
| GET /v2/sync/status p50 / p95 (ms) | 857.04 / 884.04 | 0.35 / 0.40 |
| MCP get_freshness p50 / p95 (ms) | 57.32 / 69.15 | 37.74 / 49.20 |
| MCP get_metrics, 90 populated days p50 / p95 (ms) | 15.73 / 32.06 | 14.92 / 29.42 |
| MCP get_sleep, 30 nights p50 / p95 (ms) | 8.21 / 11.14 | 7.53 / 10.72 |
| MCP list_workouts p50 / p95 (ms) | 6.00 / 9.50 | 6.11 / 9.12 |
| Cold process, empty DB p50 / p95 (ms) | 290.07 / 290.90 | 284.95 / 290.22 |
| Cold process, 1M DB p50 / p95 (ms) | 257.87 / 271.13 | 251.70 / 254.46 |

An earlier candidate run (before the last HAE source-ranking compatibility fix) recorded 20.03 ms. The final maximum is an observed ingest-window result, not a universal 20 ms guarantee. MCP freshness remains synchronous and can itself exceed 20 ms during a backfill.

An additional five-round probe schedules /health, authenticated sync status and MCP freshness together during a 5K ingest. It confirms that reads no longer wait for the ingest transaction; freshness still has its own synchronous work. Both fixtures start at the same 1,012,000-parent size before this supplementary probe.

| Concurrent probe | Baseline | Final |
| --- | --- | --- |
| health p50 / p95 (ms) | 2,293.78 / 2,509.00 | 8.68 / 28.44 |
| status p50 / p95 (ms) | 2,293.79 / 2,509.01 | 8.69 / 28.44 |
| freshness p50 / p95 (ms) | 2,348.54 / 2,593.70 | 46.35 / 110.47 |
| batch p50 / p95 (ms) | 1,389.65 / 1,605.82 | 300.43 / 395.17 |

## Storage after checkpoint

No VACUUM is used. The sample-ledger figure includes its indexes, dictionaries and quantity projections/summaries; it excludes retained bodies, point children and other MCP read models. Whole-file totals include every table/index and free page. Packed page bytes per kind are apportioned by encoded bytes; original child-table page allocations are exact. ECG JSON originally shares sample pages, so its per-voltage figure is logical encoded bytes.

| Storage metric | dcfe6d3 | Final |
| --- | --- | --- |
| Checkpointed database | 1,158.65 MiB | 290.01 MiB |
| Total file bytes / parent sample | 1,200.53 | 300.49 |
| Sample ledger + indexes/dictionaries/summaries, B / parent | 1,141.59 | 257.24 |
| Route/series child pages (including ECG blob after) | 18.64 MiB | 4.42 MiB |
| quantity allocated B / stored point | 169.90 | 33.56 |
| route allocated B / stored point | 161.87 | 70.88 |
| heartbeat allocated B / stored point | 111.68 | 9.40 |
| ECG logical encoded B / voltage | 18.90 | 8.00 |
| Retained compressed body bytes | 28.80 MiB | 28.13 MiB |
| Retained compressed body bytes / DB | 2.49% | 9.70% |
| Payload table + indexes allocated / DB | 2.50% | 9.80% |

The baseline incorrectly retains 600 tombstoned quantity-series points; the fixed ledger removes them. Raw-body retention occupies a larger fraction of the smaller final DB even though the total file shrank by 74.97%.

## Measured stages and rejected trials

Stages are serialized disk-backed runs; the cache stage also includes the correctness fixes. Compact/worker snapshots include the aggregate-plan correction. No timings are claimed from the initial tmpfs trials: this machine's /tmp is RAM-backed and filled during an early repeated run. All tables above use ext4 disk files with random UUID index locality.

| Stage | HR objects/s | Cumulative objects/s | Max ingest timer interval | DB after checkpoint |
| --- | --- | --- | --- | --- |
| baseline | 2,627 | 2,402 | 3,577.66 ms | 1,158.65 MiB |
| statement-cache | 4,538 | 3,866 | 2,174.12 ms | 1,194.99 MiB |
| set-based | 5,218 | 4,276 | 1,731.83 ms | 1,194.99 MiB |
| compact | 8,308 | 6,766 | 1,792.27 ms | 290.51 MiB |
| worker | 8,258 | 6,726 | 17.53 ms | 290.54 MiB |
| final | 11,091 | 8,777 | 18.08 ms | 290.01 MiB |

The first compact aggregate plan was rejected: at 105,000 rows a batch took 4,450 ms because SQLite flattened json_each into a ledger scan. Materialized touched groups and constrained indexed joins reduced the same checkpoint to about 491 ms. The actual plan now has a regression test.

The isolated key/PRAGMA sweep uses 1M rows per variant, cached inserts and realistic random UUID locality. It excludes parsing/validation/derivation and is not end-to-end ingest throughput.

| Layout/settings trial | Rows/s | 10K point lookups (ms) | B/sample |
| --- | --- | --- | --- |
| integer-text-4k | 19,151 | 163.69 | 225.22 |
| blob-without-rowid-4k | 14,966 | 150.73 | 190.43 |
| integer-text-8k | 17,890 | 195.97 | 222.15 |
| integer-text-16k | 17,140 | 234.75 | 220.86 |
| integer-text-64m | 20,526 | 148.27 | 225.22 |
| integer-text-mmap | 19,226 | 129.21 | 225.22 |
| integer-text-checkpoint | 23,558 | 138.20 | 225.22 |

BLOB WITHOUT ROWID saved space but was slower than integer rowids. 8/16 KiB pages regressed inserts. Mmap barely changed insert throughput, while improving the 10K lookup time; it is retained for reads. Larger cache and checkpoint batches improved the measured storage path.

## Retention codecs

Builtin Node zstd is available without dependencies on this Node version. The mixed-shape comparison measures 12 compression observations after three warmups and verifies lossless decode. Existing gzip/HAE payloads retain their bytes, and replay supports both codecs.

| Shape | gzip bytes | zstd bytes | gzip p50 / p95 ms | zstd p50 / p95 ms |
| --- | --- | --- | --- | --- |
| heart_rate | 91,195 | 82,889 | 7.86 / 8.15 | 3.44 / 3.64 |
| cumulative | 93,218 | 77,239 | 7.53 / 7.78 | 3.17 / 4.02 |
| sleep | 82,518 | 56,466 | 7.76 / 9.74 | 2.38 / 2.63 |
| route | 705,718 | 142,103 | 58.39 / 59.43 | 5.23 / 6.96 |
| ecg | 226,806 | 220,236 | 15.72 / 15.99 | 6.61 / 7.00 |

The full benchmark's separate cumulative compression probe has a small size tradeoff: gzip 131,185 B at 14.63 ms, zstd 132,030 B at 4.77 ms. Zstd is 0.64% larger for that body and materially faster; the mixed route body is much smaller and faster. Gzip remains the runtime fallback and can be forced with VITALIS_PAYLOAD_CODEC=gzip.

## Profile and remaining hot spots

A separate node --cpu-prof run measures 5,000 scalar HR samples per batch on an existing >1M-row ledger, with three warmups and nine measured batches. This run excludes fixture construction and HTTP/worker transfer. Its mean ingest wall time is 612.26 ms (8,166 samples/s); phase clocks include COMMIT/checkpoint time in SQLite, and derivation SQL is counted only within derivations.

| Final phase | ms / 5K | Wall share |
| --- | --- | --- |
| Parse + envelope | 13.97 | 2.28% |
| Object validation | 37.67 | 6.15% |
| SQLite, including COMMIT/checkpoints | 370.26 | 60.47% |
| Derivations, including their SQL | 5.53 | 0.90% |
| Raw-body zstd retention | 2.97 | 0.48% |
| Canonical sample hashing | 75.13 | 12.27% |
| Other JS/transforms/dictionary work | 106.74 | 17.43% |

The CPU profile's largest self frame is transactionSQL (2,722.75 ms sampled across the complete profile), followed by statement execution. Final profiles and CPU summaries are in app/bench/results. Earlier diagnostic profile JSON predates transaction-clock attribution and labels that limitation.

Repeated named-zone validation fell from 455.20 ms to 39.76 ms per 5K after caching Intl zone checks. Remaining object validation is 6.15% of the final >1M profile, so Zod is retained for all kinds; a handwritten validator is not justified by that profile.

Remaining work is primarily SQLite/WAL commits (60.47% of this profile), canonical hashing (12.27%), and other JS/dictionary transformations (17.43%). Freshness also remains synchronous (37.74 ms median standalone; 110.47 ms p95 in the overlapping probe). The strict 20 ms ingest timer result and the 50K/s target are reported above without rounding either into a success. Performance tuning stops here as requested; these measurements let the lead evaluate a Rust path alongside the storage/commit strategy.

## Contract edits and verification

[Native sync contract](native-sync.md) changes are clarifications: 409 for a batch ID with different decoded payload SHA-256; workout statistics/fallback/distance behavior; asleep wake-day/stage-null semantics; deletion clearing ledger content while raw bodies remain; internal packed storage and codec-marked retention. Request/response field shapes, authentication, gzip HTTP support and size limits remain unchanged.

Verification completed: `cd app && npm run typecheck && npm run build && npm test` (63 passing), then `npm run bench`. All commits use Conventional Commits and the required Codex co-author trailer; hooks were not bypassed. The working branch is feat/native-sync. The interactive HTML report was checked in local Chromium at 728px and 360px, including all six tabs, overflow, and JavaScript errors. T3 headless preview was blocked by the host AppArmor configuration; no host setup was changed.
