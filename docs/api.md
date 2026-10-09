# Vitalis API

Three endpoints. Everything else is the CLI.

| Endpoint | Auth | For |
|---|---|---|
| `POST /ingest` | `ingest` or `write` token | Health Auto Export pushes and JSON exports |
| `POST /mcp` | `read` or `write` token | Agents (MCP, stateless Streamable HTTP) |
| `GET /health` | none | The reverse proxy and Docker health check |

Tokens are bearer tokens (`Authorization: Bearer vtl_…`). `/ingest` also takes the bare token (`Authorization: vtl_…`) or `X-Api-Key: vtl_…`, for senders whose header editor can't hold a space. They are created with `vitalis token create <name> --scope ingest|read|write` and stored only as SHA-256. A `read` token sees the read tools; a `write` token also sees the write tools; an `ingest` token can only push.

## Semantics every consumer needs

- **Days are the owner's local days**, taken from the offset on each value as the phone recorded it. `VITALIS_TZ` decides what "today" means when no date is given.
- **A night of sleep belongs to the day the sleeper woke up.** The night of 5→6 October is `2026-10-06`.
- **Usual** is the median of the 30 days before the day asked about. The day itself is never included. The usual range is the 10th to 90th percentile. Fewer than 7 days of history gives `usual: null` and a reason.
- **flag** is `low` or `high` when a value is outside the usual range. **reading** (`better` or `worse`) says which way is good for that metric. Neutral metrics such as weight and breathing rate get a flag but no reading.
- **A missing day is not zero.** It means nothing reached Vitalis for that day. Every read carries `freshness` (`last_sync`, `latest_day` per metric).
- **Estimates are labelled.** These are estimates: Watch energy (`active_kcal_estimate`), VO2 max, and estimated 1RM (Epley, `w × (1 + reps/30)`, for 1–12 reps only).
- **Warm-up sets** never count toward volume, working sets or records.

## POST /ingest

Set up a Health Auto Export automation with:
- **REST API**, method POST
- **Export Format** JSON, **Export Version** 2
- **Time Grouping** Day, **Summarize Data** on
- **Date Range** "Since Last Sync"
- **Batch Requests** on
- a header `Authorization: Bearer <ingest token>`

The raw body is stored (gzipped, with its SHA-256) before anything is parsed. A byte-identical push is a no-op. Values are upserted on `(metric, day, source)`, nights on `(day, source)` and workouts on their `id`. Re-sending a day (the default range resends today's partial day) replaces the earlier value.

Request headers that Health Auto Export adds, recorded with the push: `automation-name`, `automation-id`, `automation-aggregation`, `automation-period`.

Response `200`:

```json
{ "payload_id": 12, "duplicate": false,
  "counts": { "metric_days": 140, "sleep_nights": 7, "workouts": 2, "skipped_metrics": 0 },
  "warnings": [] }
```

A metric that can't be read never fails the push. It is skipped and named in `warnings`, and the raw body stays stored for `vitalis reparse`. Common warnings:
- "sent per hour or finer": set Time Grouping to Day.
- "sent as individual stages": turn Summarize Data on.
- An unknown unit for a known metric.

Errors:
- `400`: the body isn't JSON, or is JSON without `data`.
- `401`: no token, a bad token, or a read token.
- `413`: over `VITALIS_MAX_INGEST_MB`.

Metric names map to fixed keys and units. Energy kJ becomes kcal, lb becomes kg, mi becomes km, °F becomes °C. Other metrics are kept under their Health Auto Export name and unit.

| Key | Health Auto Export name | Unit | Better |
|---|---|---|---|
| resting_hr | resting_heart_rate | bpm | lower |
| hrv | heart_rate_variability | ms | higher |
| heart_rate | heart_rate (Min/Avg/Max) | bpm | — |
| respiratory_rate | respiratory_rate | breaths/min | — |
| spo2 | blood_oxygen_saturation | % | higher |
| wrist_temp | apple_sleeping_wrist_temperature | °C | — |
| steps | step_count | steps | higher |
| active_kcal | active_energy | kcal | higher |
| resting_kcal | basal_energy_burned | kcal | — |
| exercise_min | apple_exercise_time | min | higher |
| stand_hours | apple_stand_hour | hours | higher |
| distance_km | walking_running_distance | km | higher |
| flights | flights_climbed | flights | higher |
| daylight_min | time_in_daylight | min | higher |
| walking_hr | walking_heart_rate_average | bpm | lower |
| vo2max | vo2_max | ml/kg/min | higher |
| weight_kg | weight_body_mass | kg | — |
| body_fat_pct | body_fat_percentage | % | — |
| sleep_h, deep_h, rem_h, bedtime | sleep_analysis (summarised) | hours, clock | higher (sleep), earlier (bedtime) |

## POST /mcp

The server's `instructions` (sent on `initialize`) restate the semantics above in eight lines. All tools return `structuredContent` plus the same JSON as text. Failures return `isError: true` with a message meant for the agent.

### Read tools (read and write tokens)

| Tool | Input | Returns |
|---|---|---|
| `get_brief` | `day?` (default today) | `verdict` (`call`: easy · as_planned_no_records · normal · good · unknown; `reason`; `worse`; `better`; `rule`), `summary` (a paragraph to quote), `sleep`, `recovery` (resting_hr, hrv, respiratory_rate, wrist_temp, each against the usual), `activity` (yesterday), `body` (weight, 7-day averages), `training` (last session, muscles not trained for 7+ days), `freshness` |
| `get_sleep` | `from?`, `to?` (default last 7 days) | `nights[]` (asleep, fell_asleep, woke, stages, flags), `average`, `usual_before_range`, `freshness` |
| `get_metrics` | `metrics[]` (1–8 keys), `from?`, `to?` (default 30 days), `every?` day or week | `series[]` per metric: `days[]` or `weeks[]`, average, min, max, `usual_before_range`, `average_vs_usual`, and `heart_rate_band` for heart_rate |
| `list_workouts` | `from?`, `to?` (default 14 days) | strength sessions (sets per exercise, volume, working sets per muscle, overlapping Watch heart rate) and Apple Watch workouts, newest first |
| `get_workout` | `id` | one session with every set, best set and estimated 1RM per exercise, and Watch heart rate if it overlapped; or one Watch workout |
| `get_exercise_history` | `exercise` (name or id), `limit?` | recent sessions, records, and `next` (double-progression suggestion with its rule) |
| `get_training_summary` | `from?`, `to?` (default 7 days) | session counts, working sets per muscle, volume, new records, `days_since_trained` per major muscle |
| `find_exercises` | `query`, `limit?` | catalogue matches with ids, equipment, muscles and aliases |
| `get_freshness` | — | last sync, sync days and problems in the last 7 days, latest day per metric, latest workouts |

### Write tools (write tokens only)

| Tool | Input | Notes |
|---|---|---|
| `log_sets` | `sets[]` (`exercise`, `weight_kg`, `reps`, `kind`, `rpe`, `rir`, `target_*`, `performed_at`, `note`, `id`), `session_id?`, `title?` | A set joins the open session whose last set was within 3 hours, else starts one. A set `id` seen before is skipped, so retries are safe. An unclear exercise name logs nothing and returns candidates. |
| `edit_set` | `id`, any set field, `delete?`, `restore?` | Soft delete; `restore` undoes it. |
| `edit_workout` | `id`, `title?`, `notes?`, `ended_at?`, `delete?`, `restore?` | Setting `ended_at` closes the session. Apple Watch workouts are read-only. |
| `create_exercise` | `name`, `primary[]`, `secondary[]?`, `equipment?`, `aliases[]?` | Returns the existing exercise if the name is taken. |

Every call is recorded in `calls`: the tool, whether it succeeded, how long it took, and counts only, never values.

## Outbound event (optional)

With `VITALIS_HOOK_URL` and `VITALIS_HOOK_SECRET` (`whsec_…`) set, Vitalis POSTs `{"type":"sleep.ready","day":"2026-10-10","timestamp":…}` the first time a push brings the night ending today. It fires once per day: old nights from a backfill and later pushes the same day stay silent. It is signed with Standard Webhooks (`webhook-id`, `webhook-timestamp`, `webhook-signature: v1,<HMAC-SHA256>`). The payload carries no health values; the receiver reads them over MCP. Delivery is tried 3 times. `get_freshness.last_event` shows the last attempt.

## CLI

```
vitalis token create <name> --scope ingest|read|write
vitalis token list | token revoke <id|name>
vitalis import <export.json> [...]     backfill from a Health Auto Export manual JSON export (same parser as /ingest)
vitalis reparse --all | <payload id>   re-parse stored pushes after an upgrade
vitalis syncs [n]                      the last n pushes, with counts and warnings
vitalis freshness
```

In the container: `docker exec vitalis-app node dist/src/cli.js <command>`.
