# Native ledger storage

V2 has not been deployed. This layout replaces the first v2 layout without a migration. Existing
production tables and Health Auto Export ingestion retain their formats; native changes are additive there.
The HTTP request and response shapes remain those in `native-sync.md`.

`hk_samples` uses an integer rowid and an exact, case-sensitive unique UUID string. Opaque/non-UUID
identifiers work too. `hk_types`, `hk_sources` (the entire source revision), and `hk_devices` intern
repeated values. Times use integer milliseconds, signed offset minutes, and a small formatting byte.
An uncommon sub-millisecond original timestamp is retained as an exception in the combined JSON
column. Metadata and unknown/kind-specific fields share that column; empty content is NULL.
Content hashes use 32-byte SHA-256 blobs. Tombstones retain identity, hashes for operation counts,
and deletion/audit state; all sample content and child blobs are cleared.

Ordinary scalar samples have an indexed local day and converted catalog value in the raw row.
There is no full `hk_sample_values` table. `hk_value_days` contains only series summaries and cumulative
midnight splits: count, sum, min, max per sample/day. Arithmetic means use sum/count across samples.
Raw series remain in their packed blob, so partial workout windows still select individual points.
`hk_raw` and `hk_values` are read views, not additional copies of the ledger.

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
