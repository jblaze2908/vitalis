# 12 · Server data model, computation and retention

Existing schema facts below are read from `app/src/db.ts` on `main` (commit `d3ca9ab`). New tables follow the same conventions:

- SQLite through `node:sqlite` (`DatabaseSync`), one file, WAL (`db.ts` top).
- Schema is created at module load with `CREATE TABLE IF NOT EXISTS …`. There is **no migration framework**. A new column on an existing table is added with a guarded `ALTER TABLE … ADD COLUMN` behind a `PRAGMA table_info` check, tolerating a concurrent connection (copy the `hasCodec()` pattern in `db.ts`).
- Times: UTC epoch ms integers plus a `tz_offset_min` where a local day matters (`sessions`, `sets`). Local days are `TEXT 'YYYY-MM-DD'`.
- Client-generated ids (`TEXT PRIMARY KEY`) make retried writes no-ops (`sets`, `sessions`).
- Rows are soft-deleted with `deleted_at`, never physically removed (existing rule for `sets`, `sessions`, `hk_samples`).
- Writes go through `run`/`one`/`all`/`tx` from `db.ts`. Writes from HTTP routes run on the main thread inside `tx()` (as `logSets` does). Native ingest stays in its worker thread (`app/src/v2-worker.ts`, its own SQLite connection).

All new DDL goes into `app/src/db.ts` in the existing `db.exec` block (tables) and guarded blocks after it (columns), unless noted.

## 1. What exists and is reused

| Table | Used for |
|---|---|
| `tokens` (`scope IN ('ingest','read','write')`) | Auth. The `read` scope already exists (`db.ts`, `tokens.ts` `SCOPES`). No new scope. |
| `metric_days` (metric, day, source) | Daily values (steps, active kcal, resting HR, HRV daily, weight, SpO2, breathing…) via `stats.ts` `daily()` |
| `sleep_nights` (day, source) | One row per night per source, keyed by wake day |
| `hk_samples`, `hk_values` view, `hk_value_days` | Raw native samples: overnight HRV, intra-day step/energy curves, workouts |
| `hk_workouts` | Watch workouts (HR, energy) |
| `exercises`, `sessions`, `sets` | Strength log |
| `payloads`, `hk_batches` | Sync freshness |
| `calls` | Audit of every call (counts only, never values) |

## 2. Schema changes

### 2.1 Columns added to existing tables

| Table | Column | Type | Why |
|---|---|---|---|
| `sleep_nights` | `wakeups` | `INTEGER` (nullable) | Wake-up count for the sleep score (§[11 §3.2](11-scoring.md#32-parts)). Written by the native sleep grouping in `app/src/v2-derived.ts` `Derivations.sleep()` (the `INSERT INTO sleep_nights … ON CONFLICT` statement): count of merged awake segments (`category_value = 2`) of ≥ 1 minute that lie between the first asleep segment start and the last asleep segment end of that night. Health Auto Export rows (`app/src/ingest.ts`) leave it `NULL`. `vitalis reparse --all` back-fills native nights. |
| `sessions` | `hk_workout_uuid` | `TEXT` (nullable) | Link a strength session to the `HKWorkout` the Watch (or iPhone) saved. `sessionView` in `training.ts` uses it first and falls back to today's time-overlap match. |
| `sessions` | `template` | `TEXT` (nullable) | `legs` / `push` / `pull` / null; drives the template exercise list ([11 §7.2](11-scoring.md#72-templates-v1-default)). |
| `sessions` | `client_source` | `TEXT` (nullable) | `watch` or `phone` from `POST /v2/workouts` (existing `source` column keeps its `mcp:<token>` / `rest:<token>` meaning). |

Index: `CREATE INDEX IF NOT EXISTS sessions_hk ON sessions(hk_workout_uuid) WHERE hk_workout_uuid IS NOT NULL;`

### 2.2 New tables

```sql
-- Monotonic counter bumped by every write that can change a computed value. Used for ETags (10-server-api §1.4).
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value INTEGER NOT NULL) WITHOUT ROWID;
INSERT OR IGNORE INTO meta(key, value) VALUES ('data_version', 0), ('targets_version', 0);

-- Owner targets and training preferences. One row per key; value is JSON. Defaults are computed, not stored (11 §8).
CREATE TABLE IF NOT EXISTS targets (
  key TEXT PRIMARY KEY, value_json TEXT NOT NULL, updated_at INTEGER NOT NULL) WITHOUT ROWID;

-- Weekly adaptive calorie targets (11 §8.2). week_start = Monday, local.
CREATE TABLE IF NOT EXISTS kcal_targets (
  week_start TEXT PRIMARY KEY, kcal INTEGER NOT NULL, mode TEXT NOT NULL CHECK (mode IN ('initial','adaptive','fixed','kept')),
  tdee INTEGER, intake_mean INTEGER, slope_kg_day REAL, rate_kg_week REAL, intake_days INTEGER, weigh_ins INTEGER,
  reason TEXT, computed_at INTEGER NOT NULL) WITHOUT ROWID;

-- Per-day features and cached scores (§3). One row per local day.
CREATE TABLE IF NOT EXISTS daily_derived (
  day TEXT PRIMARY KEY,
  -- features: depend only on this day's inputs
  asleep_h REAL, need_basis TEXT, bedtime_min REAL, bed_h REAL, wakeups INTEGER, awake_min REAL,
  hrv_ms REAL, hrv_basis TEXT CHECK (hrv_basis IN ('overnight','daily')), rhr_bpm REAL,
  steps_curve TEXT, kcal_curve TEXT,            -- JSON arrays of 24 cumulative fractions, or NULL
  features_at INTEGER, features_stale INTEGER NOT NULL DEFAULT 1,
  -- scores: depend on this day plus the 60 days before it
  sleep_json TEXT, recovery_json TEXT, scores_at INTEGER, scores_stale INTEGER NOT NULL DEFAULT 1) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS daily_derived_stale ON daily_derived(day) WHERE features_stale = 1 OR scores_stale = 1;

-- Manual weigh-ins from the app (POST /v2/weight). Projected into metric_days (§2.3).
CREATE TABLE IF NOT EXISTS weight_entries (
  id TEXT PRIMARY KEY, measured_at INTEGER NOT NULL, tz_offset_min INTEGER NOT NULL, day TEXT NOT NULL,
  kg REAL NOT NULL CHECK (kg > 0 AND kg < 500), hk_uuid TEXT, created_at INTEGER NOT NULL, deleted_at INTEGER);
CREATE INDEX IF NOT EXISTS weight_entries_day ON weight_entries(day) WHERE deleted_at IS NULL;

-- Food log. id is the client UUID (idempotent). meal_id groups items added in one action (Undo removes the group).
CREATE TABLE IF NOT EXISTS food_entries (
  id TEXT PRIMARY KEY, meal_id TEXT NOT NULL, day TEXT NOT NULL,
  slot TEXT NOT NULL CHECK (slot IN ('breakfast','lunch','snack','dinner')),
  eaten_at INTEGER NOT NULL, tz_offset_min INTEGER NOT NULL,
  name TEXT NOT NULL, portion_text TEXT, grams REAL,
  kcal REAL NOT NULL CHECK (kcal >= 0 AND kcal <= 10000), protein_g REAL, carbs_g REAL, fat_g REAL,
  source TEXT NOT NULL CHECK (source IN ('search','barcode','describe','manual','label_photo','usual','recent','saved')),
  source_ref TEXT,                 -- barcode or Open Food Facts code, saved meal id, etc.
  estimate INTEGER NOT NULL DEFAULT 0,
  hk_uuid TEXT,                    -- the HKCorrelation(food) the phone wrote, if any
  created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, deleted_at INTEGER);
CREATE INDEX IF NOT EXISTS food_entries_day ON food_entries(day, slot) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS food_entries_meal ON food_entries(meal_id);

CREATE TABLE IF NOT EXISTS saved_meals (
  id TEXT PRIMARY KEY, name TEXT NOT NULL, slot TEXT, items_json TEXT NOT NULL,
  created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, deleted_at INTEGER);

-- Open Food Facts and user-defined barcodes. status 'user' = the owner typed it after a miss ("we'll remember this barcode").
CREATE TABLE IF NOT EXISTS food_barcodes (
  code TEXT PRIMARY KEY, status TEXT NOT NULL CHECK (status IN ('found','missing','user')),
  item_json TEXT, fetched_at INTEGER NOT NULL) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS food_search_cache (
  q TEXT NOT NULL, page INTEGER NOT NULL, results_json TEXT NOT NULL, fetched_at INTEGER NOT NULL,
  PRIMARY KEY (q, page)) WITHOUT ROWID;
```

### 2.3 Manual weight projection

`POST /v2/weight` writes `weight_entries` and, in the same `tx()`, upserts a `metric_days` row: `metric='weight_kg'`, `day`, `source='Vitalis manual'`, `qty=kg` (latest entry of that day wins), `unit='kg'`, `payload_id=NULL`. A soft delete re-projects the day from the remaining entries or deletes the row. When the phone also wrote the reading to HealthKit, the exporter later sends that sample; it lands as another `metric_days` source row (source = the app's HealthKit source name) with the same value. `pickPerDay` picks one deterministically (`stats.ts`), so the duplicate never changes a number. The `latest.source` shown in Body is `VITALIS` for either.

### 2.4 Targets keys

| Key | Type | Default when unset (computed, [11 §8](11-scoring.md#8-fuel)) |
|---|---|---|
| `steps` | int | round500(median 28 d) else 8000 |
| `kcal_mode` | `"adaptive"` \| `"fixed"` | `"adaptive"` |
| `kcal` | int | initial rule; only read when `kcal_mode = fixed` |
| `protein_g` | int | round5(trend × 2.0) else 140 |
| `sleep_need_h` | number | 90th percentile rule else 8.0 |
| `wake_time` | `"HH:MM"` | median wake of 14 nights else `"07:00"` |
| `goal_weight_kg` | number \| null | null |
| `exercise_min` | int | 30 |
| `weekly_sets_min` / `weekly_sets_max` | int | 10 / 20 |
| `rest_s` | int | 120 |
| `crown_step_kg` | number | 2.5 |

## 3. How computation runs

**Decision: compute on read, with a per-day cache for history, invalidated by ingest and writes.** No scheduler, no nightly job.

Justification (per-request cost):

- One owner, a few app opens a day plus widget refreshes. The inputs for one day's scores are small: one `sleep_nights` lookup, ~61 `daily_derived` feature rows for the baseline window, and two `metric_days` reads. All are indexed primary-key or range reads (`daily_derived` PK, `metric_days` PK `(metric, day, source)`).
- *Estimate, not measured:* a `GET /v2/today` with warm caches does on the order of 10 indexed queries and < 2,000 rows read. Verify with the new bench in task S-19 (`app/bench/read-latency.mjs` already measures MCP reads on a one-year synthetic dataset; extend it to the new routes). Acceptance target: p95 under 50 ms on that dataset on the dev machine.
- Running on ingest instead would put scoring in the ingest worker on every batch (the phone sends many batches during backfill: up to 5,000 objects each, `config.ts` `MAX_BATCH_OBJECTS`), recomputing days nobody reads. Nightly would be stale in the morning, exactly when the digest is read.

Flow:

1. **Features** for day D (`daily_derived` feature columns) depend only on D's inputs. Computed when missing or `features_stale = 1`.
2. **Scores** for D depend on D's features plus the 60 previous days' features. For D ≤ today − 2 the scores are cached (`sleep_json`, `recovery_json`) and reused while `scores_stale = 0`. Today and yesterday are always recomputed on read (data still arriving).
3. **Invalidation**: a helper `markDirty(days: string[])` in new `app/src/derived.ts`:
   - `UPDATE daily_derived SET features_stale = 1 WHERE day IN (…)` (inserting placeholder rows if absent),
   - `UPDATE daily_derived SET scores_stale = 1 WHERE day BETWEEN min(days) AND date(max(days), '+60 days')`,
   - `UPDATE meta SET value = value + 1 WHERE key = 'data_version'`.
   Callers: end of the `applyV2` transaction in `app/src/v2.ts` (days = metric group days + sleep nights touched by `Derivations`; expose them as `derived.touchedDays`), end of `ingest()` in `app/src/ingest.ts` (days written), and every write route (food, workouts, weight, targets). Targets changes bump `targets_version` and set `scores_stale = 1` for all rows (sleep need affects duration scores).
4. **Training** freshness, due, weekly sets: computed on read from `sets` of the last 30 days (a few hundred rows). Not cached.
5. **Food day**: on read (`SUM` over `food_entries` for the day).
6. **Adaptive kcal**: computed lazily on the first read in a new week and stored in `kcal_targets`; recomputed if the owner edits goal weight or mode.
7. **Activity curves** are features of past days (`steps_curve`, `kcal_curve`), so each past day's curve is computed once.

Concurrency: reads run on the main thread's connection. The ingest worker writes on its own connection; WAL lets reads proceed during ingest. A cache row written by a read while a batch commits is corrected on the next read because the batch marks the day dirty after it.

## 4. Retention

| Data | Retention |
|---|---|
| `daily_derived`, `kcal_targets`, `targets` | Forever (tiny: one row per day/week/key). |
| `food_entries`, `weight_entries`, `saved_meals`, `sessions`, `sets` | Forever; deletes are soft (`deleted_at`), matching existing tables. |
| `food_barcodes` | `found`: refetch after 30 days. `missing`: refetch after 1 day. `user`: forever. |
| `food_search_cache` | 7 days. Rows older than that are deleted on insert (one `DELETE … WHERE fetched_at < ?`). |
| Describe (LLM) requests | Nothing stored except the `calls` row (tool name, ok, ms, item count). The text the owner typed is not stored unless they add the items, and then only as item names. |
| `payloads`, `hk_*` | Unchanged (existing). |

## 5. Backups and replay

Existing `deploy/backup.sh` backs up the SQLite file; new tables are inside it. `vitalis reparse --all` re-derives native projections including the new `wakeups`; afterwards it must call `markDirty` for every reparsed day (task S-02).
