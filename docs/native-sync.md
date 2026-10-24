# Native app sync (v2)

The contract between Vitalis and its own iPhone + Apple Watch app. The phone reads HealthKit
directly and sends **every sample as HealthKit stores it**, with its UUID, plus deletions.
Health Auto Export and `POST /ingest` keep working unchanged alongside it.

All `/v2` routes take the same tokens as the rest of the API (`Authorization: Bearer vtl_…`).
The app uses one `write` token, kept in the iOS Keychain.

## POST /v2/samples

Auth: `ingest` or `write`. Body: JSON, optionally `Content-Encoding: gzip`. The same size limit as
`/ingest` (`VITALIS_MAX_INGEST_MB`). Hard caps per batch: at most 5,000 `upserts` + `deletions` combined, and
separately at most 5,000 `daily_stats`. A larger batch gets `413` with the counts and the limit, before anything is
applied or the body is kept; split it into more batches.

```json
{
  "schema": 1,
  "batch_id": "6F1C…",                 // client UUID; same batch_id and payload is a no-op (200, duplicate: true)
  "client": { "install_id": "…", "app_version": "0.1.0", "os": "iOS 26.1", "model": "iPhone17,1" },
  "upserts":   [ /* Sample, below */ ],
  "deletions": [ { "uuid": "…", "type": "HKQuantityTypeIdentifierStepCount" } ],
  "daily_stats": [ /* DailyStat, below */ ]
}
```

### Sample (every kind)

| Field | Type | Notes |
|---|---|---|
| `uuid` | string | `HKObject.uuid`. The primary key. A re-sent UUID replaces the stored row. |
| `type` | string | HealthKit identifier, e.g. `HKQuantityTypeIdentifierHeartRate`, `HKCategoryTypeIdentifierSleepAnalysis`, `HKWorkoutTypeIdentifier`. |
| `kind` | string | `quantity`, `category`, `workout`, `correlation`, `route`, `heartbeat`, `ecg`, `state_of_mind`, `other`. |
| `start`, `end` | string | ISO 8601 with the device's UTC offset at upload, millisecond precision. |
| `tz` | string? | `HKMetadataKeyTimeZone` when the sample has it, else null. |
| `source` | object | `{ name, bundle_id, version, product_type, os_version }` from `sourceRevision`. |
| `device` | object? | `HKDevice`: `{ name, manufacturer, model, hardware_version, firmware_version, software_version, local_identifier, udi_device_identifier }`, nulls allowed. |
| `metadata` | object? | All metadata. Dates become ISO strings; `HKQuantity` values become `{ "value": n, "unit": "…" }`. |

Kind-specific fields:

- **quantity**: `value` (number), `unit` (HealthKit unit string, e.g. `count/min`, `kcal`, `m`, `kg`, `ms`, `%`, `degC`).
  The app uses one fixed unit per type. If `count > 1` (a quantity series, e.g. workout heart rate), also
  `series: [[start, end, value], …]` from `HKQuantitySeriesSampleQuery`, in the same unit.
- **category**: `value` (int, the raw enum) and `value_label` (e.g. `asleepCore`, `asleepDeep`, `asleepREM`, `awake`, `inBed`, `asleepUnspecified`).
- **workout**: `activity_type` (raw int) and `activity_name` (e.g. `traditionalStrengthTraining`), `duration_s`,
  `events: [{ type, start, end, metadata }]`,
  `activities: [{ uuid, activity_type, activity_name, start, end, metadata, statistics }]`,
  `statistics: { "<quantity type>": { sum, min, avg, max, unit } }`.
- **route** (`HKWorkoutRoute`): `workout_uuid` and
  `points: [[t, lat, lon, alt_m, h_acc_m, v_acc_m, speed_mps, course_deg], …]` where `t` is ISO 8601.
  Routes can be replaced, so a re-sent route UUID replaces its points.
- **heartbeat** (`HKHeartbeatSeriesSample`): `beats: [[seconds_since_start, preceded_by_gap], …]`.
- **ecg**: `classification`, `symptoms_status`, `avg_hr`, `sampling_hz`, `voltages_uv: [n, …]` (lead I).
- **correlation** (blood pressure, food): `objects: [uuid, …]`. The member samples are sent as their own upserts.
- **state_of_mind**: `state_kind`, `valence`, `labels: [int]`, `associations: [int]`.
- **other**: anything else, as `payload` (the fields above that apply, plus whatever the type has).

### DailyStat

HealthKit merges overlapping sources (Watch and iPhone both counting steps) by the user's source
priority. Vitalis doesn't try to rebuild that merge. The phone also sends Apple's own merged daily
values, computed with `HKStatisticsCollectionQuery` over local days:

```json
{ "type": "HKQuantityTypeIdentifierStepCount", "day": "2026-10-23", "tz": "Asia/Kolkata",
  "sum": 9120, "min": null, "avg": null, "max": null, "unit": "count" }
```

Cumulative types send `sum`; discrete types send `min`, `avg` and `max`. The phone sends every day
that any sample in the batch touches. These feed the existing `metric_days` rows with source `''`.

### Response

```json
{ "batch_id": "6F1C…", "duplicate": false,
  "counts": { "inserted": 4810, "updated": 12, "unchanged": 170, "deleted": 3, "daily_stats": 9, "rejected": 1 },
  "rejected": [ { "uuid": "…", "reason": "…" } ] }
```

- The whole decoded JSON body is stored compressed in `payloads` (origin `v2`) before parsing, so a
  parser fix can be replayed with `vitalis reparse`. Retention uses builtin zstd when available, with
  gzip as a fallback; HTTP compression remains optionally gzip. Payload SHA-256 covers decoded JSON bytes.
- The batch is applied in one transaction. A malformed envelope is `400` and nothing is applied.
- Reusing a `batch_id` with a different payload SHA-256 returns `409`; no objects are applied.
- A single bad object is `rejected` with a reason. The rest still apply.
- The phone advances its HealthKit anchor only after a `200`. A rejected object is logged on the phone
  and not re-sent; the stored body lets the server recover it after a fix.
- A deletion marks the row deleted (`deleted_at`). It is never physically removed. Deleting an unknown
  UUID stores a tombstone, so a late upsert of that UUID stays deleted.

### What Vitalis derives

Raw samples are the source of truth. The existing tables stay, filled from them, so every MCP tool
keeps working:

- `metric_days` with source `''` from `daily_stats`. Per-source rows come from raw samples.
- `sleep_nights` from sleep-stage samples, grouped into nights by the existing rule: the night belongs
  to the day the sleeper woke up.
- `hk_workouts` from workout samples. Heart rate min, avg and max come from workout statistics,
  falling back to heart rate samples inside the workout. Distance uses the first present distance statistic.

## GET /v2/sync/status

Auth: any token. For the app's sync and setup screens. Returns what the calling token can do, the server's
version, clock and time zone, the last batch time, totals per `type` (live and deleted), the newest sample
`end` per type, and the last 20 batches with counts and rejections.

Response `200` (times are ISO 8601; empty storage returns null and empty arrays):

```json
{
  "token": { "name": "iphone", "scope": "write", "can_push": true, "can_read": true, "can_write": true },
  "server": { "version": "0.1.0", "time": "2026-10-23T17:30:02+05:30", "tz": "Asia/Kolkata" },
  "last_batch_at": "2026-10-23T12:00:00.000Z",
  "types": [
    { "type": "HKQuantityTypeIdentifierStepCount", "live": 100, "deleted": 2,
      "newest_end": "2026-10-23T17:20:00.123+05:30" }
  ],
  "batches": [
    { "batch_id": "6F1C…", "payload_id": 12, "received_at": "2026-10-23T12:00:00.000Z",
      "counts": { "inserted": 100, "updated": 0, "unchanged": 0, "deleted": 2, "daily_stats": 1, "rejected": 0 },
      "rejected": [] }
  ]
}
```

`can_push` is true for `ingest` and `write` tokens, `can_read` for `read` and `write`, `can_write` for `write` only;
setup shows "connected" only when `can_write` is true, since logging food and workouts needs it. `server.version`
is `app/package.json`'s version. Types are sorted by identifier. `newest_end` is the original `end` of the newest **live** sample
(by instant), or null when none are live. Deleted totals include unknown-UUID tombstones once,
even after a late upsert. Batches are newest first, with payload id breaking timestamp ties;
duplicate attempts do not create batches or advance `last_batch_at` or MCP `last_sync`.

## Phase 1 implementation clarifications

The following choices resolve details not fixed by the original contract:

- All envelope fields in the example are required, including the three arrays (which may be empty)
  and the four client fields. Identifiers are nonempty opaque strings; UUID formatting/case is not
  normalized. Source `name` and `bundle_id` are required; revision fields are optional/null, and
  `os_version` can be a string or an object. Timestamps require an explicit offset (`Z` accepted);
  fractional seconds are preserved, and timestamps without fractional seconds are also accepted.
  An invalid IANA `tz`, nonfinite number, or interval ending before it starts rejects that object.
- Unknown sample fields, source/device/metadata fields, and unmapped types remain stored. Unknown
  units stay raw without writing a misleading derived value. Quantity series, routes, heartbeat beats, and ECG voltages use lossless packed binary
  blobs, replaced wholesale on upsert; other kind-specific fields share a JSON column with metadata. Sample equality compares all parsed JSON content with object keys sorted;
  object key order alone is unchanged. Array order and absent versus null fields remain significant.
- Counts describe raw row operations: the first accepted UUID is inserted, changed content is
  updated, identical content is unchanged. A first deletion marker counts as deleted even for an
  unknown UUID; repeated deletions do not. A late upsert stores only identity and the deleted state.
  Deletion clears series, route, heartbeat and ECG content from the ledger; raw bodies remain for replay.
  Upserts run before deletions in a batch, so deletion wins. A deletion whose type differs
  from an existing sample is rejected. Duplicate batches return the original counts/rejections with
  `duplicate: true`, only for an identical payload SHA-256; a different body returns `409`. Rejections without a
  usable sample UUID (including bad daily statistics) use `uuid: null`.
- A sample's IANA `tz`, when present, determines historical local days; otherwise its own ISO offset
  does. A cumulative quantity interval crossing midnight is split proportionally by elapsed time,
  accounting for DST with a named zone; the endpoint is exclusive. Discrete quantities use the
  start day. Series points replace the parent value for aggregation; discrete averages are arithmetic
  means of points (or scalar samples), not duration-weighted means. Per-source keys use source names,
  as the existing tables do. Only `daily_stats` writes merged source `''`; deleting raw samples does
  not infer new Apple-merged totals, so the phone must send replacement daily statistics.
- Every catalog quantity maps to its equivalent HealthKit type. `stand_hours` uses the category
  `HKCategoryTypeIdentifierAppleStandHour` (`stood` = raw value 0 contributes one hour, idle contributes
  zero); `HKQuantityTypeIdentifierAppleStandTime` is a different measure and remains raw. A daily
  stand-hour statistic, if supplied, uses that category identifier, `sum`, and unit `count`.
  Native `%` values use [HKUnit.percent()](https://developer.apple.com/documentation/healthkit/hkunit/percent%28%29):
  1.0 means 100%, converted to the existing catalog's 0–100 scale for both oxygen and body fat.
- Sleep segments from the same source form a session when they overlap or the gap is at most three
  hours, including an enclosing in-bed interval. The session belongs to the local day its last asleep segment
  ends (falling back to all members only when none are asleep); separate sessions waking on the same day combine in that day's row. Asleep includes raw enum
  values 1/3/4/5 (unspecified/core/deep/REM); awake is 2, in-bed is 0. Overlapping intervals count once
  within each stage and across total asleep. Bed edges come from in-bed segments; sleep edges come
  from asleep segments. Core/deep/REM columns are null when the source has no staged segments (3/4/5); otherwise
  absent stages are zero. Awake is null when the source has no awake segments.
- Workout HR uses its own heart-rate statistics first. When absent, live scalar samples or series
  points fully inside the window (including endpoints) are used: prefer matching source name and
  bundle id, otherwise use all sources. Means are arithmetic. No readings means null HR columns. Later HR batches and deletions refresh overlapping native workouts. Workout
  energy/distance use their statistics sums with conversion to the catalog units.
- Accepted-size decoded bodies are durably compressed with origin `v2` before JSON/envelope validation; malformed
  envelopes retain their body and `payloads.error` but apply no batch or derived changes. Both wire and
  decompressed bodies enforce `VITALIS_MAX_INGEST_MB` (413). Broken gzip is 400 and unsupported content
  encoding is 415. A database/transaction failure rolls back the batch, records the payload error, and
  returns 500 so the phone retries rather than advancing its anchor.
- Reparse bypasses batch dedupe for the original accepted payload, repairs projections even for
  unchanged content, and updates batch counts/rejections. It never overwrites a raw sample or daily
  statistic accepted in a later payload, never removes tombstones, and never applies a duplicate
  attempt's replacement body. Successfully accepted batches also feed MCP freshness; malformed and
  duplicate attempts do not count as syncs. `reparse --all` reports malformed stored envelopes and
  continues to later payloads, exiting nonzero if any payload failed.

## Training

Training moved out of this contract. The app logs a session with `POST /v2/workouts` (one idempotent upsert per
session, sets joined explicitly by the session's client id, deletions as `{ "id": …, "deleted": true }`), reads the
catalog with `GET /v2/exercises?since=`, and creates custom exercises with `POST /v2/exercises`. Schemas, rules and
errors are in `docs/api.md` (and `spec/10-server-api.md` §6).
