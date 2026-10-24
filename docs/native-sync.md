# Native app sync (v2)

The contract between Vitalis and its own iPhone + Apple Watch app. The phone reads HealthKit
directly and sends **every sample as HealthKit stores it**, with its UUID, plus deletions.
Health Auto Export and `POST /ingest` keep working unchanged alongside it.

All `/v2` routes take the same tokens as the rest of the API (`Authorization: Bearer vtl_…`).
The app uses one `write` token, kept in the iOS Keychain.

## POST /v2/samples

Auth: `ingest` or `write`. Body: JSON, optionally `Content-Encoding: gzip`. The same size limit as
`/ingest` (`VITALIS_MAX_INGEST_MB`). The phone keeps a batch to about 5,000 objects (a client choice,
not a server rule).

```json
{
  "schema": 1,
  "batch_id": "6F1C…",                 // client UUID; a batch_id seen before is a no-op (200, duplicate: true)
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

- The whole body is stored gzipped in `payloads` (origin `v2`) before parsing, as `/ingest` does, so a
  parser fix can be replayed with `vitalis reparse`.
- The batch is applied in one transaction. A malformed envelope is `400` and nothing is applied.
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
- `hk_workouts` from workout samples. Heart rate min, avg and max come from heart rate samples inside
  the workout.

## GET /v2/sync/status

Auth: any token. For the app's sync screen. Returns the last batch time, totals per `type` (live and
deleted), the newest sample `end` per type, and the last 20 batches with counts and rejections.

## Training (phase 2)

These are HTTP routes over the same functions as the MCP training tools (`app/src/training.ts`).

- `GET /v2/exercises?since=<ISO>`: the full catalog, or what changed since, for the Watch's offline picker.
- `POST /v2/exercises`: create a custom exercise (same input as `create_exercise`).
- `POST /v2/workouts`: one Watch workout, with
  `{ session: { client_id, title, started_at, ended_at, tz_offset_min, hk_workout_uuid }, sets: [SetIn] }`.
  The session client id is idempotent and the set ids are too, as with `log_sets`. Sets join this session
  explicitly, not by the 3-hour rule.
- `GET /v2/workouts?from&to` and `GET /v2/workouts/:id`: the same shapes as `list_workouts` and `get_workout`.
