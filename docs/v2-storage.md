# Native ledger storage

V2 has not been deployed. This layout replaces the first v2 layout without a migration. Existing
production tables and Health Auto Export ingestion retain their formats; native changes are additive there.
The HTTP request and response shapes remain those in `native-sync.md`.

`hk_samples` uses an integer rowid and an exact, case-sensitive unique UUID string. Opaque/non-UUID
identifiers work too. `hk_types`, `hk_sources` (the entire source revision), and `hk_devices` intern
repeated values. Times use integer milliseconds, signed offset minutes, and a small formatting byte.
An uncommon sub-millisecond or negative-zero-offset original timestamp is retained as an exception in the combined JSON
column. Metadata and unknown/kind-specific fields share that column; empty content is NULL.
Content hashes use 32-byte SHA-256 blobs. Tombstones retain identity, hashes for operation counts,
and deletion/audit state; all sample content and child blobs are cleared.

Ordinary scalar samples have an indexed local day and converted catalog value in the raw row.
There is no full `hk_sample_values` table. `hk_value_days` contains only series summaries and cumulative
midnight splits: count, sum, min, max per sample/day. Arithmetic means use sum/count across samples.
Raw series remain in their packed blob, with indexed point bounds, so partial workout windows still select individual points.
`hk_raw` and `hk_values` are read views, not additional copies of the ledger. They call the `hk_iso` SQL function,
which the app registers on each of its connections, so another connection (the `sqlite3` CLI, a SQL editor) cannot
query them: it fails with `no such function: hk_iso`. Read the base tables there, or go through the app.

`hk_type_status` maintains live/deleted counters and newest live end in the same ingest transaction.
`hk_sleep_bounds` and the per-type maximum duration bound interval seeks without excluding long
samples. Derived `metric_days`, `sleep_nights`, and `hk_workouts` retain the existing MCP interfaces.

## Packed binary v1

`hk_blobs` has one blob per sample, keyed by integer sample id. All multibyte fields are little-endian.
Every numeric measurement uses Float64, preserving all finite JSON numbers without Float32 rounding.

The 12-byte header is version:u8 (=1), kind:u8 (quantity=0, route=3, heartbeat=4, ECG=5), stride:u16,
count:u32, and trailer byte length:u32. The fixed records follow, then an optional UTF-8 JSON trailer.

| Kind | Stride | Record layout |
|---|---:|---|
| Quantity series | 32 | start_ms:f64, end_ms:f64, value:f64, start_offset:i16, end_offset:i16, start_format:u8, end_format:u8, padding:u16 |
| Route | 68 | time_ms:f64, offset:i16, format:u8, padding:u8, lat:f64, lon:f64, altitude:f64, h_accuracy:f64, v_accuracy:f64, speed:f64, course:f64 |
| Heartbeat | 9 | seconds:f64, preceded_by_gap:u8 |
| ECG | 8 | voltage_uv:f64 |

Timestamp format stores the decimal digit count (0–3) in bits 0–1 and the `Z` suffix in bit 2.
Format 255 refers to an exact original timestamp in the trailer. Trailer keys are `<index>s` and
`<index>e` for quantity starts/ends, or `<index>` for route times. Array order is record order.
Replacing a UUID replaces its whole blob; deleting it removes the blob and day summaries.

## Upgrades and rollback

- At startup `hk_types.metric` and `cumulative` are re-synced from `HK_METRICS` for every type (types no longer
  mapped get `metric = NULL`). Rows already derived under the old mapping (`metric_days`, `sleep_nights`,
  `hk_workouts`) are not rewritten by that: after a mapping change, run `vitalis reparse --all`.
- A database that ran the first v2 layout (commit `dcfe6d3`: `hk_samples` without `type_id`) has its `hk_*` native
  tables and views dropped at startup, with one log line. They are all derivable; `payloads`, `hk_workouts` and every non-`hk_*`
  table are untouched. Run `vitalis reparse --all` to rebuild them.
- Rolling back to the pre-v2 release is safe: the new tables and the `payloads.codec` column are additive, and the
  old code ignores them (`codec` defaults to `gzip`). It cannot read native (`v2`) payloads, so
  don't run its `reparse --all` over a database that holds them. Rolling back to `dcfe6d3` is
  not safe: its startup `CREATE INDEX ... ON hk_samples(type, ...)` fails against this layout's `hk_samples`.

## Execution and retention

Every ingest write is serialised in this one worker: native batches and Health Auto Export `/ingest` pushes share its
queue (the `afterIngest` hook runs on the main thread after the worker replies). MCP write tools and hooks stay on the
main thread with `busy_timeout=3000`; they are small, and a native batch is capped at 5,000 upserts + deletions and
5,000 `daily_stats` (413 above), so a writer lock is held for a bounded time.

HTTP native ingestion, gzip decoding, JSON parsing, validation, hashing, compression, SQLite writes,
and projection updates run in a `worker_threads` worker with a separate connection. The HTTP/MCP
thread reads WAL snapshots; token-use and call-audit writes retry without waiting on a writer lock.
The worker transfers large HTTP buffers without copying their contents. Queue admission is bounded
at 32 batches / 128 MiB of wire bodies; overflow returns 503 for retry with the same batch id.
The synchronous ingest function remains available for CLI replay and profiling.

`payloads.codec` is an additive column defaulting to `gzip`, so every old payload and HAE writer
retains its existing format. Native payloads use builtin zstd on supported Node versions; gzip is
the fallback and can be selected with `VITALIS_PAYLOAD_CODEC=gzip`. `body_gz` keeps its legacy column
name; replay dispatches by codec. The SHA-256 always covers the decoded JSON bytes, independent of
HTTP or retention compression. No retained raw bodies are discarded.

SQLite keeps WAL and `synchronous=NORMAL`. Fresh files use 4 KiB pages; existing files retain their
page size. Each connection has a 64 MiB page cache, a 256 MiB mmap ceiling, memory temporary storage,
and an 8,192-page automatic checkpoint threshold. The schema/PRAGMA sweep and end-to-end results
are recorded in `app/bench/results` and the performance report. These are measured choices for this
machine, not a universal SQLite tuning prescription.
