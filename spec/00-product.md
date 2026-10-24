# 00 · Product

What the owner does with Vitalis, how the app is organised, and what it shows first. Decisions marked **(user)** were made by the owner (decision log `vitalis-native-app-design.md`, 24 Oct 2026); the rest are design decisions of this package. Numbers in examples are example data.

## 1. Journeys

Each journey lists the screens (PNG in [`design/`](design/INDEX.md)) and the endpoints behind them.

### J1 · Morning digest
1. The owner wakes; the Watch has the night. The phone's exporter uploads it in the background (existing `SyncEngine`).
2. First time the app opens after waking, the **morning digest** covers Today (`02-morning-digest.png`): greeting, two-line headline ("You slept well. / Ready to push."), Sleep score with its four parts, Recovery with HRV and resting HR, yesterday's steps/active kcal/workout, and today's plan (up to three rows). **(user: digest on first open after waking)**
3. "Start my day" dismisses it; Today shows (`03-home-today.png`). The date label on Today re-opens the digest.
- Endpoints: `GET /v2/digest`, `GET /v2/today`. Trigger rules in §5.

### J2 · Gym session (Watch or iPhone)
1. Today or Train says "Legs are due" with **Start legs on Watch** (`03-home-today.png`, `06-train-tab.png`).
2. The start-choice sheet (`11-workout-start-choice.png`) offers Start on Watch or Log on iPhone, with "remember my choice". **(user: workouts can be logged from the iPhone too)**
3. **Watch path:** the Watch opens on set entry for Squat, prefilled from last time (`31-watch-set-entry.png`); Crown changes weight, double tap or tap logs the set, the rest ring runs around the edge (`32-watch-rest.png`); after the planned sets the next exercise is handed off; End → summary with the session's muscle map and PR mark (`33-watch-summary.png`). Works with no phone nearby; sets reach the server via the phone later. **(user: manual logging; auto exercise recognition dropped)**
4. **iPhone path:** the set table (`12-workout-logging-iphone.png`) with last/kg/reps/check per set, rest bar, add set/exercise, Finish → session detail (`09-session-detail-push.png`).
5. Afterwards Train shows the session; Exercise detail (`10-exercise-detail-bench-press.png`) shows estimated 1RM trend and "next time, try".
- Endpoints: `GET /v2/training`, `GET /v2/exercises/:id`, `POST /v2/workouts`, `GET /v2/training/sessions/:id`.

### J3 · Log a meal
1. Today shows `+ LOG LUNCH`; Eat (`07-eat-tab.png`) shows the usual for the next meal as a one-tap red button.
2. Other ways: Quick add (`13-quick-add-food.png`: usual, recent, saved), Search (`14-food-search.png`, Open Food Facts via the server), Scan (`16-barcode-scan.png`, with the not-found fallback `17-scan-not-found.png`: photograph the label, describe, or type numbers), Describe (`15-describe-and-confirm.png`, server-side LLM estimate, "check portions").
3. After adding: the meal shows `JUST NOW` and an Undo toast (`18-eat-just-added.png`). Undo removes it from the server and from Apple Health.
- Endpoints: `GET /v2/food/day`, `GET /v2/food/quick`, `GET /v2/food/search`, `GET/PUT /v2/food/barcode/:code`, `POST /v2/food/describe`, `POST /v2/food/entries`, `DELETE /v2/food/meals/:meal_id`.

### J4 · Weekly review
1. Train → this week: freshness map, sessions, working sets, muscles hit (`06-train-tab.png`); weekly sets per muscle against the 10–20 range.
2. Sleep → week of scores, average and bedtime spread (`04-sleep-tab.png`).
3. Body → weight trend and month change toward goal, activity week, vitals (`05-body-tab.png`). The calorie target adjusts weekly from the weight trend and intake (note on Eat).
- Endpoints: `GET /v2/training?week=`, `GET /v2/sleep/week`, `GET /v2/body`, `GET /v2/targets`.
- No separate Trends tab: the older J4 "Week vs last" frames are superseded; weekly views live in each tab.

### J5 · Why do I feel off
1. Today's Recovery is low (`EASE` or `REST`); the headline says so ("Go easy on legs", "Rest today").
2. Tap Recovery → Sleep tab: which part pulled the score down (e.g. bedtime `75 MIN LATE`, flagged).
3. Tap HRV / Resting → Body vitals: today's value against the typical range.
4. Every number shows its parts against the owner's own usual; nothing is a black box. **(research: no black-box score; parts visible)**
- Endpoints: `GET /v2/today`, `GET /v2/sleep`, `GET /v2/body`.

### J6 · First run
Welcome (`19-setup-welcome.png`) → Connect server (`20-setup-connect-server.png`: URL + write token; Continue only when the token can write) → Health access (`21-setup-health-access.png`: reads plus writes for weight, nutrition, workouts) → Reading your history (`22-setup-reading-history.png`: backfill progress, can continue while it runs) → Targets (`23-setup-targets.png`: suggestions from history) → Today.
- Before 14 nights of history, Recovery shows "Needs N more nights" (calibrating) while everything else works.
- Endpoints: `GET /v2/sync/status`, `GET/PUT /v2/targets`; HealthKit; the existing exporter.

### J7 · Sync broke
1. Today shows the stale state when the last sync is older than 12 hours (`24-state-today-sync-stale.png`): `LAST SYNC WED`, the cause, "Everything is safe on this phone until it's fixed", **Fix sync**.
2. Sync screen with token rejected (`25-state-sync-token-rejected.png`): "Nothing is lost", counts of batches, food and Watch sets waiting, **Replace token** / Try again.
3. After a new token, the exporter and the outbox drain; the banner clears.
- Endpoints: any 401 response; `GET /v2/sync/status`; local exporter and outbox state.

## 2. Five pillars

**(user)** Vitalis is built only from: **sleep**, **Apple Watch metrics** (heart, activity), **weight** (Apple Health import and manual entry, source shown, manual written back to Health), **workouts** (strength sets logged on Watch or iPhone, plus Watch workouts), **calories** (logged food against an adaptive target).

## 3. Information architecture

Five tabs **(user)**: `TODAY · SLEEP · BODY · TRAIN · EAT`.

| Tab | Holds | Not here |
|---|---|---|
| Today | Verdict + one action, Recovery (Sleep as a sub-score), Fuel, Activity, Training due + freshness | Weight **(user: weight in Body only)** |
| Sleep | Sleep score + parts, week, tonight's bed-by; stages one tap down | — |
| Body | Weight trend + log, activity (steps, active kcal, exercise min) + week, vitals vs typical range | — |
| Train | Freshness map, due template + start, week stats, sessions → session → exercise | — |
| Eat | Calories left + macros, add (usual, search, scan, describe), meals, adaptive target note | — |

Settings (server, targets, training preferences, sync, acknowledgements) is reached from Today's header and `vitalis://settings`.

## 4. Metric hierarchy and the fixed-order Home

**(user)** Hero metrics: **Recovery** (sleep + HRV + resting HR, parts visible), **Activity** = steps **and** active energy against usual, **Fuel** = calories left (protein second), **Training due** (+ muscle freshness). Sleep score sits inside Recovery as a sub-score. Weight lives in Body only.

**(user)** Order by importance, **fixed all day** (only content changes):

1. Verdict headline + one action (`NOW · READY` / "Train legs hard today" / Start legs on Watch).
2. Recovery: score with Sleep, HRV, Resting rows.
3. Fuel left | Activity (steps, with ahead/behind usual by now; active kcal pace in the same block's second line of data from `activity.active_kcal_*`).
4. Training: muscle map + "Legs fresh / Chest loaded".

The frame shows steps only in the Activity column; active energy is available in the same response (`activity.active_kcal`, `active_kcal_pace`) and is shown as a second mono line `212 ACTIVE KCAL · ON PACE` under the steps line (design decision to honour the hierarchy without changing the frame's layout).

Tier 2 (one tap down) and Tier 3 (tabs) per the decision log: stages, SpO2, breathing, wrist temperature, VO2 max, walking HR, distance, flights, stand, macros, workout history, PRs, e1RM, weekly sets per muscle.

## 5. Morning digest trigger

Server decides **availability**, the phone decides **display**:

- `available` (server, `GET /v2/today` → `digest.available`): a night exists for today (keyed by wake day) and its `sleep_end` is at least 30 minutes ago. Only the first night of the day counts; naps never re-trigger.
- Display (phone): on `scenePhase == .active`, if `available` and `digestDismissedDay` (UserDefaults) ≠ today → present. "Start my day" sets `digestDismissedDay = today`. Relaunching the same day never shows it again. The date label re-opens it without touching the flag.
- No night today → no digest; Today shows Recovery as missing ("No sleep recorded for last night").

## 6. States (product level)

| State | What the owner sees |
|---|---|
| First days (fewer than 14 nights) | Recovery `–`, "Needs N more nights"; Sleep score works from night one (consistency part appears after 14 nights). |
| Night missing | Recovery `–`, "No sleep recorded for last night"; digest not shown. |
| Offline | Last cached data, `OFFLINE · UPDATED HH:MM`; logging still works and syncs later (`WAITING TO SYNC`). |
| Sync stale (> 12 h) | Stale banner with cause and Fix sync (J7). |
| Token rejected | Sync paused screen; nothing lost (J7). |
| No workouts yet | Empty Train frame (`26-state-train-empty.png`). |
| Nothing eaten today | Empty Eat frame (`27-state-eat-empty.png`), full target to go. |
| Describe not set up on the server | Describe tile hidden; one line in Search. |

No streaks, no guilt mechanics, sync freshness always visible so a missed sync never reads as a bad day (research note).
