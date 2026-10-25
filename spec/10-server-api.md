# 10 · Server API (new and changed)

Base: the existing Hono app in `app/src/server.ts` (`main`). Existing routes stay unchanged: `GET /health`, `POST /ingest`, `POST /v2/samples`, `GET /v2/sync/status` (extended in §2), `ALL /mcp`.

Formulas behind every number: [11-scoring.md](11-scoring.md). Tables: [12-data-model.md](12-data-model.md). Screens that read each route: [20-ios-app.md](20-ios-app.md), [21-watch-app.md](21-watch-app.md).

All example payloads use **example data**.

## 1. Conventions

### 1.1 Files

New routes go in new files, registered from `server.ts`, so `server.ts` stays a router:

| File | Routes |
|---|---|
| `app/src/http.ts` | auth helper, ETag helper, error helper (§1.2–1.5) |
| `app/src/routes/read.ts` | today, digest, sleep, sleep/week, body, training, sessions, exercises (GET) |
| `app/src/routes/write.ts` | targets (PUT), weight, workouts, exercises (POST) |
| `app/src/routes/food.ts` | everything under `/v2/food` |

Business logic stays in modules (`scoring.ts`, `training.ts`, `training-analytics.ts`, `fuel.ts`, `activity.ts`, `derived.ts`, `food.ts`, `off.ts`, `describe.ts`) so the MCP tools call the same functions (§8).

### 1.2 Auth and scopes

Token header: `Authorization: Bearer vtl_…` (existing `authenticate()` in `app/src/tokens.ts`; `x-api-key` also accepted as on `/ingest`).

Scopes already exist (`tokens.ts`: `ingest | read | write`). **No new scope is added**: the read-only scope the task asked for is the existing `read`.

| Route group | `ingest` | `read` | `write` |
|---|---|---|---|
| All new `GET` routes | 403 | ✓ | ✓ |
| All new `POST`/`PUT`/`DELETE` routes | 403 | 403 | ✓ |
| `GET /v2/sync/status` | ✓ (exporter-only tokens keep working) | ✓ | ✓ |

- Missing or invalid token → **401** `{"error":"Missing or invalid token","code":"unauthorized"}`.
- Valid token, wrong scope → **403** `{"error":"This token can't …; use a write token","code":"scope"}`. (Existing `/ingest` and `/v2/samples` keep their current 401 behaviour.)
- The iPhone app uses one `write` token (existing, Keychain `TokenStore`). Widgets and the Watch never call the server.
- Helper: `requireToken(c, need: "read" | "write"): Token` in `http.ts`; every call is logged with `logCall(token.id, "<route name>", ok, ms, detail)` with counts only, never values (existing convention, `calls` table).

### 1.3 Errors

JSON body `{"error": "<human sentence>", "code": "<snake_case>"}`. Domain errors use the existing `HttpError` (`app/src/config.ts`); a route catches it and returns its status. Unknown errors: log with `console.error`, return 500 `{"error":"Vitalis couldn't do that; see the server log","code":"internal"}` (never the internal message, matching `server.ts` and `mcp.ts`).

| Status | `code` | When |
|---|---|---|
| 400 | `bad_request` | Malformed JSON, invalid date, unknown query value |
| 401 | `unauthorized` | Missing/invalid/revoked token |
| 403 | `scope` | Token scope too low |
| 404 | `not_found` | Unknown id |
| 409 | `conflict` | Client id reused with different immutable content (e.g. a set id under another session) |
| 413 | `too_large` | Body over 1 MB (all new write routes) |
| 422 | `invalid` | Body valid JSON but fails the zod schema; `error` names the first bad field |
| 429 | `rate_limited` | Describe or Open Food Facts limits (§7) |
| 503 | `unavailable` | Describe not configured, or Open Food Facts down with no cache |

Validation uses `zod` (already a dependency, `app/package.json`), schemas next to the route.

### 1.4 Caching: ETag and 304

Every new `GET` returns:

- `ETag: W/"<data_version>.<targets_version>.<route key>"` where `data_version` and `targets_version` come from the `meta` table ([12 §2.2](12-data-model.md#22-new-tables)) and `route key` is the route plus its normalised query, plus the current local 15-minute bucket for every route whose body reads the clock: `/v2/today`, `/v2/digest` (verdict, pace, digest availability), `/v2/training` (muscle load decays continuously, `trained_today`), `/v2/food/day` and `/v2/food/quick` (`just_added`, `next_slot`). `/v2/sleep`, `/v2/sleep/week`, `/v2/body`, `/v2/training/sessions*`, `/v2/exercises*` and `/v2/targets` use the versions only.
- `Cache-Control: private, no-cache` (the client may store it but must revalidate).
- If the request's `If-None-Match` equals the ETag, respond **304** with no body **before computing anything** (one `SELECT` on `meta`).

`/v2/food/search` and `/v2/food/barcode/:code` use `Cache-Control: private, max-age=3600` instead (external data, not owner data).

### 1.5 Dates, times, numbers

- `date` query params are local days `YYYY-MM-DD` (`DAY_RE` in `time.ts`); default = today in `VITALIS_TZ`. A date more than 1 day in the future → 400.
- Timestamps in responses are ISO 8601 with the owner's offset (`isoAt()` in `time.ts`), e.g. `2026-10-24T09:39:00+05:30`.
- Units are fixed per field and named in the key (`_kg`, `_h`, `_min`, `_ms`, `_bpm`, `_g`, `kcal`).
- Missing is `null`, never 0 (existing rule `NO_ROW` in `health.ts`).

### 1.6 Freshness block

Every read response carries:

```json
"freshness": {
  "last_sync": "2026-10-24T09:39:00+05:30",
  "data_through": { "sleep": "2026-10-24", "heart": "2026-10-24", "activity": "2026-10-24", "weight": "2026-10-23", "food": "2026-10-24", "training": "2026-10-22" },
  "today": "2026-10-24"
}
```

`last_sync` = the existing `freshFor()` `last_sync` (`health.ts`: last accepted push, failed attempts excluded). `data_through` = latest day per domain (`latestDays()` for sleep_h/hrv/steps/weight_kg; max `food_entries.day`; latest session day). The app decides the stale banner from this ([20 §6](20-ios-app.md#6-offline-cache-and-stale-rules)).

### 1.7 Pagination

Lists that can grow without bound use a cursor: `?before=<opaque>&limit=<n>` (default 20, max 50). Response: `"next": "<opaque>" | null`. The cursor is `base64url("<started_at ms>:<id>")`. Only `/v2/training/sessions` and `/v2/food/search` (page-number, §7.4) paginate in v1.

---

## 2. GET /v2/sync/status (changed)

Existing response (`syncStatus()` in `app/src/v2.ts`, documented in `docs/native-sync.md`) gains two blocks. Auth unchanged (any token).

```json
{
  "token": { "name": "iphone", "scope": "write", "can_push": true, "can_read": true, "can_write": true },
  "server": { "version": "0.2.0", "time": "2026-10-24T09:41:02+05:30", "tz": "Asia/Kolkata" },
  "last_batch_at": "2026-10-24T04:09:00.000Z",
  "types": [ { "type": "HKQuantityTypeIdentifierStepCount", "live": 100, "deleted": 2, "newest_end": "2026-10-24T09:20:00.123+05:30" } ],
  "batches": [ { "batch_id": "6F1C…", "payload_id": 12, "received_at": "2026-10-24T04:09:00.000Z",
                 "counts": { "inserted": 100, "updated": 0, "unchanged": 0, "deleted": 2, "daily_stats": 1, "rejected": 0 }, "rejected": [] } ]
}
```

- `can_push` = scope is `ingest` or `write`; `can_read` = `read` or `write`; `can_write` = `write`.
- Setup step "Connect server" shows `CONNECTED · TOKEN CAN WRITE` only when `token.can_write` is true; otherwise it shows `THIS TOKEN CAN'T LOG WORKOUTS OR FOOD` in `watch` and blocks Continue. This is the "verify write scope" fix.
- `server.version` = `app/package.json` version (read once at startup).

## 3. Targets

### GET /v2/targets — read

```json
{
  "values": { "steps": 9000, "kcal_mode": "adaptive", "kcal": null, "protein_g": 160, "sleep_need_h": 8.0, "wake_time": "07:00",
              "goal_weight_kg": 74.0, "goal": "lose", "exercise_min": 30, "weekly_sets_min": 10, "weekly_sets_max": 20, "rest_s": 120, "crown_step_kg": 2.5 },
  "effective": { "steps": 9000, "kcal": 2300, "protein_g": 160, "sleep_need_h": 8.0, "wake_time": "07:00", "bed_by": "23:00" },
  "suggested": {
    "steps": { "value": 8500, "basis": "YOUR USUAL IS 8,600" },
    "kcal": { "value": 2300, "basis": "ADJUSTS WEEKLY FROM WEIGHT" },
    "protein_g": { "value": 155, "basis": "2.0 G PER KG" },
    "sleep_need_h": { "value": 8.0, "basis": "FROM YOUR LAST 60 NIGHTS" },
    "goal_weight_kg": { "value": null, "basis": "NOW 76.4 KG" }
  },
  "plan": { "goal": "lose", "goal_weight_kg": 74.0, "trend_kg": 76.4, "rate_kg_week": -0.38, "maintenance_kcal": 2450,
            "kcal": 2030, "kcal_mode": "adaptive", "basis": "watch", "reached": false },
  "is_set": { "steps": true, "protein_g": true, "sleep_need_h": false, "goal_weight_kg": true, "goal": true },
  "freshness": { "…": "…" }
}
```

`values` = what the owner stored (null when unset). `effective` = what scoring uses now (stored or computed default, [11 §8](11-scoring.md#8-fuel), and this week's `kcal_targets` row for adaptive kcal). `suggested` feeds the Targets setup screen (`spec/design/23-setup-targets.png`). `plan` explains the calorie target for the goal sheet ([11 §8.2](11-scoring.md#82-calorie-target)): `goal` is the stored goal, else the direction the goal weight implies (`null` with neither); `basis` is `adaptive` (logged food and weight), `watch` (resting + active energy) or `estimate` (30 kcal/kg); `reached` = a goal weight is set and the trend is within 0.5 kg of it or past it.

### PUT /v2/targets — write

Partial update; only keys present change. `null` clears a key back to its computed default.

```json
{ "steps": 9000, "protein_g": 160, "goal_weight_kg": 74.0, "kcal_mode": "adaptive" }
```

Validation: steps 1000–50000; kcal 1000–6000; protein_g 30–400; sleep_need_h 5–11 (step 0.25); wake_time `HH:MM`; goal_weight_kg 30–300; goal `lose` | `maintain` | `gain`; exercise_min 0–300; weekly_sets 0–60 with min ≤ max; rest_s 15–600; crown_step_kg one of 0.5, 1, 1.25, 2, 2.5, 5. Unknown key → 422. Response: the `GET /v2/targets` body. Effects: bump `targets_version`, mark all scores stale ([12 §3](12-data-model.md#3-how-computation-runs)); changing `goal`, `goal_weight_kg`, `kcal_mode` or `kcal` recomputes this week's `kcal_targets` row.

---

## 4. Today and digest

### GET /v2/today — read

Query: `date` (default today). The Home screen (`spec/design/03-home-today.png`) renders this body without arithmetic.

```json
{
  "day": "2026-10-24",
  "generated_at": "2026-10-24T09:41:02+05:30",
  "verdict": {
    "band": "ready", "label": "READY",
    "headline": "Train hard today",
    "reason": "Recovery 82: HRV above your usual, resting heart rate slightly up.",
    "action": { "kind": "start_workout", "label": "Start workout", "template": null, "intensity": "normal" }
  },
  "recovery": {
    "score": 82, "band": "ready", "status": "ok", "reason": null, "nights_of_history": 60, "nights_needed": 0,
    "parts": {
      "sleep": { "score": 86, "band": "good" },
      "hrv": { "value": 62, "unit": "ms", "basis": "overnight", "usual": 55, "usual_range": [48, 61], "z": 1.2, "score": 93, "arrow": "up", "tint": "good" },
      "resting_hr": { "value": 57, "unit": "bpm", "usual": 55, "usual_range": [54, 56], "z": -1.0, "score": 60, "arrow": "up", "tint": "watch" }
    }
  },
  "fuel": {
    "kcal_target": 2300, "kcal_eaten": 520, "kcal_left": 1780,
    "protein_target_g": 160, "protein_g": 38,
    "next_slot": "lunch", "next_label": "LOG LUNCH"
  },
  "activity": {
    "steps": 3206, "steps_target": 9000, "steps_expected_now": 2600, "steps_pace": "ahead",
    "active_kcal": 212, "active_kcal_expected_now": 240, "active_kcal_pace": "on_pace"
  },
  "training": {
    "heat": { "abdominals": 1, "abductors": 0, "adductors": 1, "biceps": 2, "calves": 1, "chest": 4, "forearms": 1, "glutes": 1, "hamstrings": 1,
              "lats": 2, "lower-back": 1, "middle-back": 2, "neck": 0, "quadriceps": 1, "shoulders": 3, "traps": 1, "triceps": 3 },
    "fresh_label": "Lower fresh", "loaded_label": "Chest loaded",
    "due": null,
    "splits": [ { "id": "lower", "name": "Lower", "source": "defined", "ready": true, "days_since": 6,
                  "exercises": [ { "id": "barbell-squat", "name": "Barbell Squat" }, { "id": "romanian-deadlift", "name": "Romanian Deadlift" } ] },
                { "id": "history:push", "name": "Push", "source": "history", "ready": false, "days_since": 1, "exercises": [ { "id": "barbell-bench-press-medium-grip", "name": "Barbell Bench Press - Medium Grip" } ] } ],
    "trained_today": false
  },
  "pulse": {
    "window": { "start": "2026-10-24T06:51:00+05:30", "end": "2026-10-24T23:00:00+05:30" },
    "now": "2026-10-24T09:41:02+05:30",
    "events": [ { "at": "2026-10-24T06:51:00+05:30", "kind": "wake" }, { "at": "2026-10-24T08:12:00+05:30", "kind": "meal" } ]
  },
  "digest": { "available": true, "night_ended_at": "2026-10-24T06:51:00+05:30" },
  "freshness": { "last_sync": "2026-10-24T09:39:00+05:30", "data_through": { "sleep": "2026-10-24" }, "today": "2026-10-24" }
}
```

Field rules:

- `recovery.status`: `ok` | `calibrating` (fewer than 14 nights; `nights_needed` > 0; `reason`: "Needs 9 more nights") | `missing` (`reason`: "No sleep recorded for last night" or "No heart data for last night"). When not `ok`, `score` and `band` are `null` and the part objects still carry whatever exists.
- `fuel.next_slot`: slot windows (local): breakfast 04:00–10:29, lunch 10:30–14:59, snack 15:00–17:59, dinner 18:00–03:59. Next slot = the current window's slot if it has no entries yet, else the following slot. `next_label` = `LOG <SLOT>` (`LOG SNACK`).
- `activity.*_pace` values: `ahead | behind | on_pace | early | unknown` ([11 §6](11-scoring.md#6-activity-ahead--behind-usual-by-now)).
- `training.heat` always has all 17 slugs ([11 §7.1](11-scoring.md#71-muscle-load-and-heat-17-muscles)). `splits` lists the owner's splits, defined then history, each with `ready` ([11 §7.2–7.3](11-scoring.md#72-splits)); it may be empty. `due` is always `null`; it stays only so older app builds still decode.
- `pulse` resolves the PulseLine time→x question: `window.start` = today's wake (`sleep_end` of today's night; 06:00 local if none), `window.end` = `bed_by` ([11 §9.2](11-scoring.md#92-tonight)). Events (each draws a dip): `wake`, `weigh_in` (weight entry or HealthKit weight sample time), `meal` (first `eaten_at` of each `meal_id`), `workout` (session `started_at`). Events after `now` are omitted. The app maps `x = (t − start) / (end − start)` clamped to 0…1.
- `digest.available`: see `GET /v2/digest`.
- `recovery.bands` = the band floors `{ready, steady, ease}` (below `ease` is rest), so the app draws the band bar without its own copy. `recovery.parts.hrv.week` and `resting_hr.week`: seven daily values ending on `day`, oldest first, `null` where none was recorded (Today's sparklines).
- `sleep`: the night ending on `day` (`asleep_h`, `need_h` after any nap credit, `score`, `band`), or `null` when there's no night. Naps are not in `asleep_h` ([11 §3](11-scoring.md)).

### GET /v2/digest — read

Query: `date` (default today). Drives `spec/design/02-morning-digest.png`.

```json
{
  "day": "2026-10-24", "available": true, "night_ended_at": "2026-10-24T06:51:00+05:30",
  "date_label": "SAT 24 OCT", "greeting": "GOOD MORNING",
  "headline": ["You slept well.", "Ready to push."],
  "sleep": {
    "score": 86, "band": "good",
    "rows": [
      { "key": "duration", "label": "DURATION", "value": "7H41", "delta": "+12M", "tint": "good" },
      { "key": "bedtime", "label": "BEDTIME", "value": "23:02", "delta": "18M LATE", "tint": null },
      { "key": "efficiency", "label": "EFFICIENCY", "value": "94%", "tint": null },
      { "key": "wakeups", "label": "WAKE-UPS", "value": "2", "tint": "watch" }
    ]
  },
  "recovery": { "score": 82, "band": "ready", "label": "READY",
                "hrv": { "value": 62, "arrow": "up", "tint": "good" }, "resting_hr": { "value": 57, "arrow": "up", "tint": "watch" } },
  "yesterday": { "day": "2026-10-23", "steps": 9420, "active_kcal": 640, "workout": { "id": "3d0c…", "title": "Push", "kind": "strength" } },
  "plan": [
    { "kind": "train", "title": "Train", "reason": "LOWER READY", "primary": true },
    { "kind": "eat", "title": "Eat 2,300 kcal", "reason": "160 G PROTEIN", "primary": false },
    { "kind": "walk", "title": "Walk 9,000", "reason": "YOUR TARGET", "primary": false }
  ],
  "pulse": { "window": { "start": "…", "end": "…" }, "now": "…", "events": [ { "at": "…", "kind": "wake" } ] },
  "freshness": { "…": "…" }
}
```

- `available` = a night exists for `date` **and** its `sleep_end` is at least 30 minutes before now (design default "settle window"). Only the first night of the day counts; a nap later does not re-trigger.
- `headline`: [11 §5.1](11-scoring.md#51-digest-copy). `sleep.rows[].delta` for duration = asleep − 60-night median (`+12M`/`−25M`); bedtime delta from consistency (`18M LATE`); `tint` per row = `watch` when that part's score < 70, `good` when duration is ≥ need.
- `yesterday.workout` = the latest strength session or Watch workout on the previous day, else `null` (the app shows `REST · NO WORKOUT`). `active_kcal` = active energy (the Activity pillar), not total.
- When `available` is false, the body still returns (with `sleep`/`recovery` null when no night) so the app can show the digest on demand from the date label.
- Display rule (client): show once per day on first foreground when `available` and the local `digestDismissedDay != day` ([20 §4 Morning digest](20-ios-app.md#morning-digest)).

---

## 5. Sleep and body

### GET /v2/sleep?date= — read

`date` = wake day (default today). Drives `spec/design/04-sleep-tab.png`.

```json
{
  "day": "2026-10-24", "has_night": true, "prev_day": "2026-10-23", "next_day": null,
  "night": { "sleep_start": "2026-10-23T23:02:00+05:30", "sleep_end": "2026-10-24T06:51:00+05:30",
             "in_bed_start": "2026-10-23T22:55:00+05:30", "in_bed_end": "2026-10-24T07:05:00+05:30",
             "asleep_h": 7.68, "asleep_label": "7H41", "source": "Apple Watch" },
  "score": 86, "band": "good", "label": "GOOD", "status": "ok",
  "duration": { "asleep_label": "7H41", "vs_usual_min": 12, "vs_usual_label": "+12M", "need_h": 8.0, "need_label": "8H00", "need_basis": "target" },
  "parts": [
    { "key": "duration", "label": "DURATION", "detail": "OF YOUR 8H NEED", "score": 90, "flagged": false, "weight": 0.4 },
    { "key": "consistency", "label": "BEDTIME", "detail": "18 MIN LATE", "score": 85, "flagged": false, "weight": 0.2 },
    { "key": "efficiency", "label": "EFFICIENCY", "detail": "94% ASLEEP", "score": 97, "flagged": false, "weight": 0.2 },
    { "key": "wakeups", "label": "WAKE-UPS", "detail": "2 · 25 MIN", "score": 70, "flagged": false, "weight": 0.2 }
  ],
  "stages": { "core_h": 4.1, "deep_h": 1.2, "rem_h": 1.9, "awake_h": 0.42, "note": "Stages are estimates and are not part of the score." },
  "tonight": { "bed_by": "23:00", "wake_time": "07:00", "need_h": 8.0, "label": "8H BEFORE YOUR 07:00 WAKE" },
  "freshness": { "…": "…" }
}
```

- Missing part → `score: null`, `detail` explains (`NEEDS 14 NIGHTS`, `NO IN-BED TIME`); the app shows `–`.
- `has_night: false` → `score`, `parts`, `night`, `stages` null; `tonight` still present.
- `next_day` is null when `date` is today.

### GET /v2/sleep/week?end= — read

`end` default today. Seven entries, oldest first.

```json
{
  "end": "2026-10-24",
  "nights": [ { "day": "2026-10-18", "score": 81, "asleep_h": 7.2 }, { "day": "2026-10-19", "score": null, "asleep_h": null } ],
  "avg_score": 81, "bedtime_spread_min": 24, "label": "AVG 81 · BED ± 24M",
  "freshness": { "…": "…" }
}
```

### GET /v2/body?date= — read

Drives `spec/design/05-body-tab.png`.

```json
{
  "day": "2026-10-24",
  "weight": {
    "trend_kg": 76.4, "month_change_kg": -0.6, "goal_kg": 74.0, "toward_goal": true,
    "latest": { "kg": 76.6, "at": "2026-10-24T07:02:00+05:30", "source": "SCALE", "manual": false },
    "series": [ { "day": "2026-09-25", "raw_kg": 77.0, "trend_kg": 77.02 }, { "day": "2026-09-26", "raw_kg": null, "trend_kg": 77.02 } ]
  },
  "activity": {
    "steps": 3206, "steps_target": 9000, "active_kcal": 212, "exercise_min": 12, "exercise_target_min": 30,
    "week": [ { "day": "2026-10-18", "steps": 8210 }, { "day": "2026-10-24", "steps": 3206 } ]
  },
  "vitals": [
    { "key": "hrv", "label": "HRV", "value": 62, "unit": "ms", "usual": 55, "usual_range": [48, 61], "flag": "high", "reading": "better" },
    { "key": "resting_hr", "label": "RESTING HR", "value": 57, "unit": "bpm", "usual": 55, "usual_range": [54, 56], "flag": "high", "reading": "worse" },
    { "key": "spo2", "label": "SPO2", "value": 97, "unit": "%", "usual": 97, "usual_range": [95, 98], "flag": null, "reading": null },
    { "key": "respiratory_rate", "label": "BREATHING", "value": 14.8, "unit": "/min", "usual": 15.0, "usual_range": [14.2, 15.8], "flag": null, "reading": null }
  ],
  "freshness": { "…": "…" }
}
```

- `series`: 30 days ending `date`, one point per day; `raw_kg` from `daily("weight_kg")` (picked source per day), `trend_kg` from [11 §8.1](11-scoring.md#81-weight-trend).
- `latest.source`: the HealthKit source name of the picked row, uppercased and shortened to its first word (`SCALE`, `HEALTH`), or `VITALIS` for manual entries.
- `vitals` use the existing `compare()` in `stats.ts` with the 60-day window: `flag` low/high outside the 10th–90th percentile range; `reading` better/worse from metric polarity (`catalog.ts`); neutral metrics (breathing) never get `reading`.

### POST /v2/weight — write

**Why this exists beyond HealthKit write-back:** the Log weight sheet has an "Also save to Apple Health" toggle (`spec/design/08-log-weight-sheet.png`). With it off, a reading would otherwise never reach the server. With it on, the HealthKit path only arrives after the exporter's next upload, but the Body tab must show the new trend immediately after Save. So the app always posts; the server dedupes as in [12 §2.3](12-data-model.md#23-manual-weight-projection).

```json
{ "id": "8E2B1C4A-…", "kg": 76.6, "measured_at": "2026-10-24T07:05:00+05:30", "hk_uuid": "A1B2…" }
```

- `id` client UUID (idempotent: same id + same body → 200 with the stored row; same id + different kg → updates it). `hk_uuid` present only when also saved to Health.
- Response 200: `{ "entry": { "id": "…", "kg": 76.6, "day": "2026-10-24" }, "weight": { …same as GET /v2/body weight block… } }`.
- `DELETE /v2/weight/:id` (write) soft-deletes and returns the updated weight block (used by the sheet's Undo; HealthKit deletion is the phone's job).

---

## 6. Training

### GET /v2/training?week= — read

`week` = any date in the wanted week (Monday-start); default this week. Drives `spec/design/06-train-tab.png`.

```json
{
  "week_start": "2026-10-19", "week_end": "2026-10-25", "label": "THIS WEEK · 19 TO 25 OCT",
  "heat": { "abdominals": 1, "…": 1, "triceps": 3 },
  "muscles": [ { "slug": "quadriceps", "heat": 1, "load": 0.39, "days_since": 6, "week_sets": 0, "status": "under" } ],
  "due": null,
  "splits": [ { "id": "lower", "name": "Lower", "source": "defined", "ready": true, "days_since": 6, "muscles": ["quadriceps", "hamstrings", "glutes", "calves"],
                "exercise_count": 5, "exercises": [ { "id": "barbell-squat", "name": "Barbell Squat", "last": { "weight_kg": 100, "reps": 6, "day": "2026-10-18" } } ] } ],
  "stats": { "sessions": 3, "working_sets": 52, "muscles_hit": 11, "muscles_total": 17 },
  "weekly_sets": { "min": 10, "max": 20, "by_muscle": { "chest": 12, "quadriceps": 0 } },
  "sessions": [
    { "id": "3d0c…", "kind": "strength", "title": "Push", "day": "2026-10-22", "start": "2026-10-22T18:42:00+05:30",
      "duration_min": 58, "working_sets": 19, "tag": { "kind": "pr", "label": "PR · BENCH" } },
    { "id": "HKW-…", "kind": "cardio", "title": "Running", "day": "2026-10-21", "duration_min": 32, "hr_avg": 148, "tag": { "kind": "cardio", "label": "CARDIO" } }
  ],
  "empty": false,
  "freshness": { "…": "…" }
}
```

`sessions` lists the week's strength sessions plus non-strength Watch workouts (existing `listWorkouts()` merge rule: a Watch workout overlapping a strength session is folded into it). `empty: true` when no strength session was ever logged (drives `spec/design/26-state-train-empty.png`).

### GET /v2/splits — read · PUT / DELETE /v2/splits/:id — write

The owner's defined splits ([11 §7.2](11-scoring.md#72-splits)), edited from Settings. History splits are not stored; they appear only in `GET /v2/training` and `/v2/today`.

```json
{ "splits": [ { "id": "push", "name": "Push", "muscles": ["chest", "shoulders", "triceps"], "ord": 0 } ] }
```

- `PUT` body: `{ "name": "Push", "muscles": ["chest", "shoulders", "triceps"], "ord": 0 }`. `id` is client-chosen (`[A-Za-z0-9_-]{1,64}`); `ord` defaults to the split's current place, or last for a new one. Muscles are the 17 slugs; unknown → 422. A name another split already has (case-insensitive) → 409. Returns the full list.
- `DELETE` soft-deletes; unknown id → 404. Returns the full list.
- `POST /v2/workouts` `session.template` = the split id the workout was started from (any string ≤ 80), or `null`.

### GET /v2/training/sessions?before=&limit= — read

Paged history (newest first) in the same row shape as `sessions` above, plus `"next"`.

### GET /v2/training/sessions/:id — read

Drives `spec/design/09-session-detail-push.png`. Builds on the existing `getWorkout()` (`training.ts`).

```json
{
  "id": "3d0c…", "kind": "strength", "title": "Push", "template": "push", "client_source": "watch",
  "start": "2026-10-22T18:42:00+05:30", "end": "2026-10-22T19:40:00+05:30", "duration_min": 58,
  "context_label": "THU 22 OCT · 18:42 · 58 MIN",
  "working_sets": 19, "volume_kg": 6420, "avg_bpm": 118, "active_kcal": 310,
  "heat": { "chest": 4, "shoulders": 3, "triceps": 3, "…": 0 },
  "exercises": [
    { "id": "barbell-bench-press-medium-grip", "name": "Barbell Bench Press - Medium Grip", "working_sets": 4,
      "top_set": { "weight_kg": 82.5, "reps": 6 }, "summary": "4 SETS · TOP 82.5 X 6", "pr": true,
      "sets": [ { "id": "…", "kind": "warmup", "weight_kg": 40, "reps": 10, "at": "…" }, { "id": "…", "kind": "normal", "weight_kg": 82.5, "reps": 6, "at": "…" } ] }
  ],
  "watch": { "workout_id": "HKW-…", "hr_avg": 118, "hr_max": 152 },
  "freshness": { "…": "…" }
}
```

A Watch-only workout id returns the existing `hk_workouts` shape with `kind: "cardio"`. Unknown id → 404.

### GET /v2/exercises?since=&q= — read

The catalog for the Watch picker and Add exercise (existing seeded free-exercise-db, 753 entries in `app/data/exercises.json`, plus custom).

```json
{
  "generated_at": "…", "count": 755,
  "exercises": [ { "id": "barbell-squat", "name": "Barbell Squat", "equipment": "barbell", "primary": ["quadriceps"],
                   "secondary": ["calves","glutes","hamstrings","lower-back"], "aliases": ["squat","back squat","squats"], "custom": false } ]
}
```

- `since` (ISO): only exercises created after it (custom ones; the seeded catalog never changes after seeding, `seedExercises()` in `exercises.ts`).
- `q`: ranked search with the existing `findExercises()`; returns at most 25.
- Muscle names use hyphen slugs. ETag as §1.4, so the phone refreshes the full list cheaply.

### POST /v2/exercises — write

Same input as MCP `create_exercise` (`mcp.ts`): `{ "name": "Cable Lateral Raise", "primary": ["shoulders"], "secondary": [], "equipment": "cable", "aliases": [] }`. Muscles accept hyphen or space slugs. Response: `{ "exercise": {…}, "created": true }` (existing `createExercise()`).

### GET /v2/exercises/:id — read

Drives `spec/design/10-exercise-detail-bench-press.png` and Watch/iPhone prefill.

```json
{
  "exercise": { "id": "barbell-bench-press-medium-grip", "name": "Barbell Bench Press - Medium Grip", "equipment": "barbell",
                "primary": ["chest"], "secondary": ["shoulders","triceps"] },
  "context_label": "BARBELL · CHEST, SHOULDERS, TRICEPS",
  "e1rm": { "current_kg": 99.0, "change_8w_kg": 3.1, "points": [ { "day": "2026-08-30", "kg": 95.9, "session_id": "…" } ], "estimate": true },
  "records": { "best_e1rm_kg": 99.0, "best_set": "82.5 kg × 6", "on": "2026-10-22", "heaviest_kg": 82.5 },
  "next": { "rule": "double progression on the top working weight; step 2.5 kg (barbell)", "last_top": "82.5 kg × 6, 6, 6, 6",
            "suggestion": "85 kg × 6 for 4 sets", "weight_kg": 85, "reps": 6, "sets": 4 },
  "last_session": { "session_id": "…", "day": "2026-10-22",
                    "sets": [ { "kind": "warmup", "weight_kg": 40, "reps": 10 }, { "kind": "normal", "weight_kg": 82.5, "reps": 6 } ] },
  "sessions_total": 14,
  "freshness": { "…": "…" }
}
```

`next` wraps the existing `suggest()` and adds machine-readable `weight_kg`/`reps`/`sets` parsed from the same values (not from the string). Unknown id → 404.

### POST /v2/workouts — write

One session from the Watch or iPhone, idempotent. Supersedes the "Training (phase 2)" sketch in `docs/native-sync.md` (update that doc in task S-19). The phone may post the same session many times as sets arrive; each post upserts.

```json
{
  "session": {
    "client_id": "5A0E9C2F-…", "title": "Lower", "template": "lower", "source": "watch",
    "started_at": "2026-10-24T18:40:00+05:30", "ended_at": null, "tz_offset_min": 330,
    "hk_workout_uuid": null, "notes": null
  },
  "sets": [
    { "id": "C1D2…", "exercise": "barbell-squat", "kind": "warmup", "weight_kg": 60, "reps": 8, "performed_at": "2026-10-24T18:44:10+05:30" },
    { "id": "C1D3…", "exercise": "barbell-squat", "kind": "normal", "weight_kg": 100, "reps": 6, "target_weight_kg": 100, "target_reps": 6,
      "rpe": null, "performed_at": "2026-10-24T18:47:30+05:30" },
    { "id": "C1D4…", "exercise": "barbell-squat", "deleted": true }
  ]
}
```

Rules:

- `session.client_id` becomes `sessions.id`. Exists → update `title`, `template`, `ended_at`, `hk_workout_uuid`, `notes` when provided. New → insert with `source = 'rest:<token name>'`, `client_source = session.source`.
- Sets join **this** session explicitly (never the 3-hour rule of `logSets`).
- Each set: new id → insert (same validation as `checkSet()` in `training.ts`; `exercise` is an id or name resolved with `resolveExercise()`; unclear name → 422 listing candidates and nothing is written). Existing id in the same session → update mutable fields (`kind`, `weight_kg`, `reps`, `duration_s`, `distance_m`, `rpe`, `rir`, `target_*`, `performed_at`, `note`, `exercise`). `deleted: true` → soft-delete. Existing id in another session → 409.
- `ord` = arrival order within the session (existing behaviour).
- Implement as `upsertWorkout(input, tokenName)` in `training.ts`, inside one `tx()`, then `markDirty([day])`.
- `source` is `watch` or `phone`; anything else 422. Max 200 sets per request.

Response 200:

```json
{
  "session": { "…": "same shape as GET /v2/training/sessions/:id" },
  "accepted": { "inserted": 2, "updated": 0, "deleted": 1, "unchanged": 0 },
  "prs": [ { "exercise_id": "barbell-squat", "exercise": "Barbell Squat", "set": "100 kg × 6", "e1rm_kg_estimate": 120, "previous_best_estimate": 116.7 } ]
}
```

`prs` drives the `PR` mark on the Watch summary (`spec/design/33-watch-summary.png`); it is computed server-side with the existing records query. When the Watch is offline the summary shows no PR until the phone has posted and relayed the answer ([21 §6](21-watch-app.md#6-transfer-to-iphone-and-the-server)).

---

## 7. Food

Slots: `breakfast | lunch | snack | dinner` (windows in §4). Every entry is server truth; the app keeps a cache and an outbox ([20 §5](20-ios-app.md#5-networking-cache-and-outbox)).

### GET /v2/food/day?date= — read

Drives `spec/design/07-eat-tab.png`, `18-eat-just-added.png`, `27-state-eat-empty.png`.

```json
{
  "day": "2026-10-24", "date_label": "TODAY · SAT 24 OCT", "prev_day": "2026-10-23", "next_day": null,
  "kcal_target": 2300, "kcal_eaten": 520, "kcal_left": 1780, "over": false,
  "macros": { "protein": { "g": 38, "target_g": 160 }, "carbs": { "g": 52, "target_g": null }, "fat": { "g": 21, "target_g": null } },
  "target_note": "TARGET 2,300 KCAL ADJUSTS WEEKLY FROM YOUR WEIGHT TREND",
  "meals": [
    { "slot": "breakfast", "label": "BREAKFAST", "time": "08:12", "kcal": 520, "just_added": false,
      "entries": [ { "id": "…", "meal_id": "…", "name": "Masala omelette", "portion_text": "3 eggs", "kcal": 310, "protein_g": 21, "carbs_g": 6, "fat_g": 22, "estimate": false, "source": "recent" } ] }
  ],
  "next_slot": "lunch",
  "usual_next": { "name": "Chicken rice bowl", "kcal": 640, "protein_g": 42, "items": [ { "name": "…", "kcal": 0 } ], "meal_signature": "…" },
  "empty": false,
  "freshness": { "…": "…" }
}
```

- `kcal_target` = this week's effective target ([11 §8.2](11-scoring.md#82-calorie-target)); `over` when `kcal_left < 0`.
- `just_added` true on a meal whose newest entry was created in the last 10 minutes (server clock), driving the `JUST NOW` label.
- `usual_next`: the usual for `next_slot` (below) or null. Carbs/fat targets are null in v1 (no rule decided; display only grams).
- `target_note` is null when `kcal_mode` is `fixed`.

### GET /v2/food/quick?slot= — read

Drives Quick add (`spec/design/13-quick-add-food.png`).

```json
{
  "slot": "lunch",
  "usual": { "name": "Chicken rice bowl", "kcal": 640, "protein_g": 42, "carbs_g": 70, "fat_g": 14, "items": [ { "name": "Chicken breast", "portion_text": "150 g", "grams": 150, "kcal": 248, "protein_g": 46, "carbs_g": 0, "fat_g": 5 } ] },
  "recent": [ { "name": "Masala omelette", "portion_text": "3 eggs", "kcal": 310, "protein_g": 21, "carbs_g": 6, "fat_g": 22, "last_day": "2026-10-24" } ],
  "saved": [ { "id": "…", "name": "Post-gym shake", "kcal": 420, "items": [ { "…": "…" } ] } ]
}
```

- **Usual** (design default): group the last 28 days' entries in this slot by `meal_id`; a meal's signature = its item names lower-cased and sorted. The most frequent signature with ≥ 3 occurrences is the usual (ties → most recent). Values = the most recent occurrence's items.
- **Recent**: the last 10 distinct item names (any slot), newest first.
- **Saved**: non-deleted `saved_meals`.

### POST /v2/food/entries — write

```json
{
  "entries": [
    { "id": "E1…", "meal_id": "M1…", "slot": "lunch", "eaten_at": "2026-10-24T13:05:00+05:30",
      "name": "Paneer tikka", "portion_text": "1 plate, 200 g", "grams": 200,
      "kcal": 420, "protein_g": 28, "carbs_g": 12, "fat_g": 29,
      "source": "describe", "source_ref": null, "estimate": true, "hk_uuid": null }
  ]
}
```

- 1–50 entries; ids are client UUIDs (same id + identical body → unchanged; same id + different body → update; `deleted_at` rows are not revived by a repost of the same body, only by a changed body). `day` is derived from `eaten_at` and its offset.
- Response: `{ "accepted": { "inserted": 1, "updated": 0, "unchanged": 0 }, "day": { …GET /v2/food/day body for that day… } }` so the app re-renders from one round trip.
- Calls `markDirty([day])` (fuel and adaptive target inputs).

### DELETE /v2/food/entries/:id and DELETE /v2/food/meals/:meal_id — write

Soft-delete one entry, or every entry of an add action (Undo on `spec/design/18-eat-just-added.png` deletes the `meal_id`). Response: `{ "deleted": 3, "day": { …food day… } }`. Unknown id → 404. Deleting twice → 200 with `deleted: 0`.

### POST /v2/food/saved, DELETE /v2/food/saved/:id — write

`{ "id": "S1…", "name": "Post-gym shake", "slot": "snack", "items": [ { "name": "…", "portion_text": "…", "grams": 30, "kcal": 120, "protein_g": 24, "carbs_g": 3, "fat_g": 1 } ] }`. Idempotent by id.

### GET /v2/food/search?q=&page= — read

Drives `spec/design/14-food-search.png`. The server proxies Open Food Facts so the app never talks to a third party.

- Open Food Facts facts (checked 24 Oct 2026): full-text search is **not** in the v2/v3 product API; their docs point to Search-a-licious at `https://search.openfoodfacts.org/` ([OFF API docs](https://openfoodfacts.github.io/openfoodfacts-server/api/)). Its OpenAPI (`https://search.openfoodfacts.org/openapi.json`) lists `GET /search` with `q`, `langs`, `page_size`, `page`, `fields`, `sort_by`; responses carry `hits`, `count`, `page`, `page_size`, `page_count`. A live call returned per-hit `product_name`, `code`, `serving_size`, and `nutriments` with keys such as `energy-kcal_100g`, `proteins_100g`, `carbohydrates_100g`, `fat_100g`.
- Limits (same docs): **10 search requests/min** and 15 product reads/min per IP, and "don't use it for search-as-you-type". A `User-Agent` of the form `AppName/Version (ContactEmail)` is required. Data is ODbL.

Server behaviour:

1. Normalise `q` (trim, lower-case, collapse spaces); `q` shorter than 2 chars → 400.
2. Local first: up to 5 matches from the owner's recent and saved items by name (`source: "recent"` / `"saved"`).
3. Remote: `food_search_cache` hit younger than 7 days → use it. Else call `GET https://search.openfoodfacts.org/search?q=<q>&page=<page>&page_size=20&fields=code,product_name,brands,serving_size,serving_quantity,nutriments` with `User-Agent: Vitalis/<version> (<VITALIS_CONTACT_EMAIL>)` and a 5 s timeout; cache it.
4. Process-wide token bucket of 8 OFF searches per minute (under their 10). Bucket empty or OFF error → return local results with `"remote": "rate_limited"` or `"remote": "unavailable"` (HTTP 200, not an error).

```json
{
  "q": "paneer", "page": 1, "remote": "ok", "count": 5,
  "results": [
    { "key": "off:8901234567890", "name": "Malai Paneer", "brand": "Amul", "source": "search", "source_ref": "8901234567890", "estimate": false,
      "per_100g": { "kcal": 314, "protein_g": 20, "carbs_g": 4.5, "fat_g": 25 },
      "serving": { "label": "100 G", "grams": 100, "kcal": 314, "protein_g": 20, "carbs_g": 4.5, "fat_g": 25 },
      "label": "100 G · OPEN FOOD FACTS" }
  ],
  "next_page": 2
}
```

- `serving` uses `serving_quantity` grams when present, else 100 g. Hits without `energy-kcal_100g` are dropped.
- The app adds a result by posting an entry with these numbers (`source: "search"`, `source_ref: code`).
- Generic dishes ("Paneer tikka") come from Describe, not search (the footer link on the frame).

### GET /v2/food/barcode/:code — read

Drives `spec/design/16-barcode-scan.png` and `17-scan-not-found.png`. `code` = 8–14 digits else 400.

1. `food_barcodes` row with `status='user'` → return it.
2. Fresh cached `found` (< 30 days) or `missing` (< 1 day) → return it.
3. Else `GET https://world.openfoodfacts.org/api/v2/product/<code>?fields=code,product_name,brands,serving_size,serving_quantity,quantity,nutriments` with the same User-Agent (product-read bucket 12/min). Checked 24 Oct 2026: an unknown code returns JSON `"status": 0`; a known one `"status": 1` with `product`.

```json
{ "code": "8901063010031", "found": true, "source": "openfoodfacts",
  "item": { "name": "Lassi", "brand": "…", "quantity_label": "200 ML BOTTLE", "per_100g": { "kcal": 72, "protein_g": 3, "carbs_g": 11, "fat_g": 2 },
            "serving": { "label": "200 ML BOTTLE", "grams": 200, "kcal": 144, "protein_g": 6, "carbs_g": 22, "fat_g": 4 } },
  "label": "200 ML BOTTLE · OPEN FOOD FACTS" }
```

Not found: `{ "code": "…", "found": false, "source": "openfoodfacts", "item": null, "label": "NOT IN OPEN FOOD FACTS YET" }` (HTTP 200). Found but without kcal → treated as not found.

### PUT /v2/food/barcode/:code — write

After a miss, the owner's fallback (photo label, describe, typed numbers) is remembered: body `{ "item": { "name": "…", "serving": { "label": "1 BAR", "grams": 40, "kcal": 190, "protein_g": 10, "carbs_g": 20, "fat_g": 7 } } }` → stored as `status='user'`. Response = the GET shape with `source: "you"`.

### POST /v2/food/describe — write

Drives `spec/design/15-describe-and-confirm.png`. Parses free text into estimated items with an LLM **on the server**; the key never reaches the app (existing principle: secrets stay on the server, `apple/README.md` Keychain note).

Request: `{ "text": "paneer tikka, 2 rotis and a bowl of dal", "slot": "lunch" }` (text 3–500 chars).

Response 200:

```json
{
  "items": [
    { "name": "Paneer tikka", "portion_text": "1 plate", "grams": 200, "kcal": 420, "protein_g": 28, "carbs_g": 12, "fat_g": 29, "confidence": "medium",
      "portion_options": [ { "label": "½ plate", "factor": 0.5 }, { "label": "1 plate", "factor": 1 }, { "label": "1½ plates", "factor": 1.5 } ] },
    { "name": "Roti", "portion_text": "2 rotis", "grams": 80, "kcal": 240, "protein_g": 7, "carbs_g": 44, "fat_g": 4, "confidence": "high", "portion_options": [ { "label": "1 roti", "factor": 0.5 }, { "label": "2 rotis", "factor": 1 }, { "label": "3 rotis", "factor": 1.5 } ] }
  ],
  "total": { "kcal": 665, "protein_g": 44, "carbs_g": 71, "fat_g": 37 },
  "estimate": true, "note": "ESTIMATED FROM YOUR WORDS · CHECK PORTIONS BEFORE ADDING"
}
```

- Nothing is stored. The app posts the confirmed items to `/v2/food/entries` with `source: "describe"`, `estimate: true` and portions scaled by the chosen `factor` (the app multiplies the server's numbers by the factor the server offered; that is display of a server-given option, not scoring).
- Implementation: `app/src/describe.ts` defines `interface MealParser { parse(text: string, slot: string): Promise<DescribedItem[]> }` with two implementations: `FixtureParser` (deterministic, used by tests and when `VITALIS_DESCRIBE=fixture`) and the provider implementation chosen in [50-open-questions.md Q1](50-open-questions.md#q1-llm-provider-and-key-for-describe). Provider output must validate against a zod schema (max 12 items, kcal 0–5000 per item); invalid → 502 `{"code":"describe_failed"}`.
- Config (env, documented in `.env.example`): `VITALIS_DESCRIBE` = `off` (default) | `fixture` | `anthropic`; `ANTHROPIC_API_KEY`; `VITALIS_DESCRIBE_MODEL`. `off` → 503 `{"code":"unavailable","error":"Describe isn't set up on this server"}`; the app then hides the Describe tile.
- Limits: 30 requests per hour per token (in-memory counter) → 429. Timeout 20 s → 504 `{"code":"describe_timeout"}`.

---

## 8. MCP tools

Agents must read the same numbers as the app (`app/src/mcp.ts`). Changes:

| Tool | Change |
|---|---|
| `get_brief` | Keeps every existing field. Adds `scores: { sleep: {score, band, parts}, recovery: {score, band, status, parts} }` and `plan: { headline, action }` from the same functions as `/v2/today`. `verdict.call` keeps its enum, now derived from the recovery band ([11 §5](11-scoring.md#5-verdict-headline--one-action)); `verdict.rule` text updated to describe the new rule. Existing `mcp.test.mjs` cases that break because of the 60-day window or the new rule are updated deliberately, each with a comment saying why. |
| `get_metrics`, `get_sleep` | Baselines now 60 days (text in descriptions and `INSTRUCTIONS` updated from "30 days"). `get_sleep` nights gain `score` and `wakeups`. |
| `get_training_summary` | Adds `heat` (17 muscles), `splits`, `weekly_sets` status. |
| `log_sets` | Sets join the open session whose last set was within 3 h (a phone or Watch workout in progress counts, since its uploads leave `ended_at` null). The reply adds `next_sets`: per exercise logged, `working_sets_today`, `today_target` (last session's double-progression suggestion, 11 §7.6) and `next` (`Set 2 of 3: 62.5 kg × 8`), so an agent can answer "and my next set?" without a second call. |
| **new** `get_today` (read) | Returns the `GET /v2/today` body. |
| **new** `get_scores` (read) | `{from, to}` (≤ 90 days): per day `sleep` and `recovery` score objects. |
| **new** `get_food_day` (read) | Returns the `GET /v2/food/day` body. |
| **new** `log_food` (write) | Input = `POST /v2/food/entries` body (ids required, so retries are safe). |
| **new** `get_targets` (read) | Returns `GET /v2/targets`. |

The tool-list assertion in `app/tests/mcp.test.mjs` ("tool lists follow the token's scope") is updated to include the new names.

## 9. Route summary

| Method | Path | Scope | Section |
|---|---|---|---|
| GET | /v2/sync/status | any | §2 |
| GET / PUT | /v2/targets | read / write | §3 |
| GET | /v2/today | read | §4 |
| GET | /v2/digest | read | §4 |
| GET | /v2/sleep | read | §5 |
| GET | /v2/sleep/week | read | §5 |
| GET | /v2/body | read | §5 |
| POST / DELETE | /v2/weight, /v2/weight/:id | write | §5 |
| GET | /v2/training | read | §6 |
| GET / PUT / DELETE | /v2/splits, /v2/splits/:id | read / write | §6 |
| GET | /v2/training/sessions | read | §6 |
| GET | /v2/training/sessions/:id | read | §6 |
| GET / POST | /v2/exercises | read / write | §6 |
| GET | /v2/exercises/:id | read | §6 |
| POST | /v2/workouts | write | §6 |
| GET | /v2/food/day | read | §7 |
| GET | /v2/food/quick | read | §7 |
| POST | /v2/food/entries | write | §7 |
| DELETE | /v2/food/entries/:id | write | §7 |
| DELETE | /v2/food/meals/:meal_id | write | §7 |
| POST / DELETE | /v2/food/saved, /v2/food/saved/:id | write | §7 |
| GET | /v2/food/search | read | §7 |
| GET / PUT | /v2/food/barcode/:code | read / write | §7 |
| POST | /v2/food/describe | write | §7 |
