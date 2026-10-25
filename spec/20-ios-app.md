# 20 · iPhone app

The iPhone app displays what the server computed, caches it for offline use, and sends raw data: HealthKit samples (the existing exporter), workouts and food. It never computes a score, baseline, trend, verdict, freshness, pace or target (user decision, [README](README.md#decided-principles)).

Visual measurements per screen (sizes, type roles, spacing) are in the revised briefs: [apple/briefs/01-today-and-digest.md](../apple/briefs/01-today-and-digest.md) and [apple/briefs/03-tabs-and-flows.md](../apple/briefs/03-tabs-and-flows.md). Tokens and components: [30-design-system.md](30-design-system.md). This file is canonical for architecture, data flow and behaviour; where a brief disagrees, this file wins.

## 1. Starting point (read from `apple/` on `feat/apple-exporter`)

- XcodeGen project `apple/project.yml`: targets `Vitalis` (iOS 18.0), `VitalisWatch` (watchOS 11.0, embedded), `VitalisTests`; local package `VitalisKit` (`apple/VitalisKit/Package.swift`, iOS 18 / watchOS 11). Swift 6, `SWIFT_STRICT_CONCURRENCY: complete`, `SWIFT_DEFAULT_ACTOR_ISOLATION: nonisolated`, so every view model needs an explicit `@MainActor`. No third-party dependencies; keep it that way.
- Exporter: `Vitalis/SyncEngine.swift` (actor, anchors, staged envelopes, `POST /v2/samples`), `Vitalis/AppModel.swift` (`@MainActor ObservableObject`, observers, BGTask `…catchup`), `Vitalis/HealthReader.swift`, `HealthSerializer.swift`, `HealthTypes.swift`. Keep the pipeline; only its UI changes.
- Networking: `VitalisKit/APIClient.swift` (`HTTPAPIClient`: ephemeral `URLSession`, 60 s timeout, `NoRedirects` delegate so the bearer token never follows a redirect, `upload()` and `status()`).
- Settings: `VitalisKit/Settings.swift` (`ServerSettings` URL validation, `TokenStore` Keychain service `Vitalis.API` account `write-token` with `AfterFirstUnlockThisDeviceOnly`, `SettingsStore.baseURL` in `UserDefaults`).
- Root UI today: `Vitalis/VitalisApp.swift` `TabView { SyncView; SettingsView }`.
- `AppModel.authorize()` requests HealthKit read types only (README: "No write access is requested on iPhone").
- **Not yet compiled.** The exporter was written on Linux (`apple/README.md`). The first Mac build may need fixes; task I-01 starts by building both schemes.

## 2. Architecture

```
VitalisKit (package, iOS + watchOS)
├── VitalisKit       existing exporter models + new: API models, VitalisAPI client, ResponseCache, Outbox, WatchMessages
└── VitalisUI        new library target: tokens, fonts, components (30-design-system.md)

Vitalis (iOS app)
├── App/             VitalisApp, AppDelegate, AppModel (existing, extended), Router, DeepLinks
├── Stores/          @MainActor @Observable stores, one per screen family (TodayStore, SleepStore, BodyStore, TrainStore, EatStore, SetupStore, SyncStore)
├── Screens/         SwiftUI views per frame
├── Health/          existing exporter files + HealthWriter (write-back, §8)
└── Watch/           PhoneSessionDelegate (WatchConnectivity receiver, 21-watch-app.md §6)
```

- **Stores** own state for a screen: `phase: .loading | .loaded(T) | .cached(T, fetchedAt) | .failed(Error, cached: T?)`. They call `VitalisAPI`, write through `ResponseCache`, and expose plain values to views. Views contain no networking and no arithmetic beyond formatting.
- **Formatting only**: number grouping (`1,780`), uppercase, joining a value and unit, mapping `pulse.events` to x positions ([10 §4](10-server-api.md#4-today-and-digest)). Anything else (deltas, ranges, labels like `AHEAD`, `18 MIN LATE`, headlines) arrives from the server as a string or enum.
- Use `@Observable` (iOS 17+) for new stores. `AppModel` stays an `ObservableObject` (existing).

## 3. Navigation and screens

Custom five-tab shell (`TODAY · SLEEP · BODY · TRAIN · EAT`), replacing the root `TabView` in `VitalisApp.swift`. The existing Sync and Settings screens move under Settings (gear in the Today header, and `vitalis://settings`).

| Screen | Frame (PNG in `spec/design/`) | Endpoint(s) | Brief section |
|---|---|---|---|
| Morning digest (full-screen cover) | `02-morning-digest.png` | `GET /v2/digest` | 01 → Morning digest |
| Today | `03-home-today.png` | `GET /v2/today` | 01 → Home |
| Today, sync stale | `24-state-today-sync-stale.png` | `GET /v2/today` (cached) + local exporter state | 01 → States |
| Sleep tab | `04-sleep-tab.png` | `GET /v2/sleep?date=`, `GET /v2/sleep/week` | 03 → Sleep |
| Body tab | `05-body-tab.png` | `GET /v2/body` | 03 → Body |
| Log weight sheet | `08-log-weight-sheet.png` | `POST /v2/weight` (+ HealthKit write) | 03 → Log weight |
| Train tab | `06-train-tab.png` | `GET /v2/training` | 03 → Train |
| Train, no workouts yet | `26-state-train-empty.png` | `GET /v2/training` (`empty: true`) | 03 → Train |
| Workout start choice (sheet) | `11-workout-start-choice.png` | `GET /v2/training` (`splits`) | 03 → Start choice |
| Workout logging on iPhone | `12-workout-logging-iphone.png` | `GET /v2/exercises/:id`, `POST /v2/workouts` | 03 → iPhone logging |
| Session detail | `09-session-detail-push.png` | `GET /v2/training/sessions/:id` | 03 → Session detail |
| Exercise detail | `10-exercise-detail-bench-press.png` | `GET /v2/exercises/:id` | 03 → Exercise detail |
| Eat tab | `07-eat-tab.png` | `GET /v2/food/day` | 03 → Eat |
| Eat, just added + Undo | `18-eat-just-added.png` | `POST /v2/food/entries`, `DELETE /v2/food/meals/:meal_id` | 03 → Just added |
| Eat, nothing logged | `27-state-eat-empty.png` | `GET /v2/food/day` (`empty: true`) | 03 → Empty Eat |
| Quick add (sheet) | `13-quick-add-food.png` | `GET /v2/food/quick?slot=` | 03 → Quick add |
| Food search | `14-food-search.png` | `GET /v2/food/search` | 03 → Search |
| Describe & confirm | `15-describe-and-confirm.png` | `POST /v2/food/describe` | 03 → Describe |
| Barcode scan | `16-barcode-scan.png` | `GET /v2/food/barcode/:code` | 03 → Scan |
| Scan not found | `17-scan-not-found.png` | `PUT /v2/food/barcode/:code` | 03 → Scan |
| Setup · Welcome | `19-setup-welcome.png` | none | 03 → Setup |
| Setup · Connect server | `20-setup-connect-server.png` | `GET /v2/sync/status` | 03 → Setup |
| Setup · Health access | `21-setup-health-access.png` | HealthKit authorisation | 03 → Setup |
| Setup · Reading your history | `22-setup-reading-history.png` | `SyncEngine.snapshot()` (local) | 03 → Setup |
| Setup · Targets | `23-setup-targets.png` | `GET /v2/targets`, `PUT /v2/targets` | 03 → Setup |
| Settings | `28-settings.png` | `GET /v2/targets`, `PUT /v2/targets`, `GET /v2/sync/status` | 03 → Settings |
| Sync, token rejected | `25-state-sync-token-rejected.png` | local exporter + Outbox state | 03 → Sync |
| Widgets | `29-widgets-home-lock.png` | `TodaySnapshot` from App Group (§9) | 03 → Widgets |

Navigation rules (owner feedback, 25 Oct): Sleep and Body keep their state across tab switches (shared stores). In-app actions open their sheet over the current tab and never change tabs (quick add, start workout); only deep links switch tabs. The Settings gear sits top-left on every tab, and Settings has a Done button. Tappable numbers on Today carry a `›`: Recovery, HRV and Resting land on Body's vitals, Steps on Body's activity, Fuel left on Eat, Sleep on Sleep, and the date opens the digest. The digest has a close button as well as Start my day. A live workout can be minimised; a resume bar then sits above the tab bar.

Deep links (register `CFBundleURLTypes` scheme `vitalis`): `vitalis://today`, `vitalis://digest`, `vitalis://sleep`, `vitalis://body`, `vitalis://train`, `vitalis://eat`, `vitalis://eat/add?slot=lunch`, `vitalis://workout/start`, `vitalis://settings`, `vitalis://settings/sync`. A link that opened the app holds back the automatic morning digest for 10 s, so Siri or a widget lands where it pointed; the digest shows on the next foreground.

## 4. Behaviour per screen (data and interactions)

Visual specifics are in the briefs; this is what each screen does.

### Today
- Renders `GET /v2/today` top to bottom in fixed order (user decision): NOW verdict + action, Recovery (score + Sleep/HRV/Resting rows), Fuel | Activity, Training (MuscleMap + labels), primary button.
- Primary button = `verdict.action`:
  - `start_workout` → start-choice sheet, or straight to the remembered choice (local `rememberedStart: .watch | .phone | nil`). Label substitution `on Watch` → `on iPhone` when remembered phone.
  - `log_meal` → Quick add for `fuel.next_slot`.
  - `bed_reminder` → schedule a local notification at `bed_by − 30 min` (ask notification permission on first use); button becomes `REMINDER SET`.
- Taps: Recovery number or Sleep row → Sleep tab; HRV/Resting → Body tab (vitals); `+ LOG <SLOT>` → Quick add; Steps → Body (activity); MuscleMap → Train; date label → digest.
- Pull to refresh: `AppModel.syncNow()` (exporter) then refetch `/v2/today` with `If-None-Match`.
- Refresh triggers: foreground, after any successful outbox flush, after `syncNow()` completes, every 15 min while foregrounded.

### Morning digest
- On each `scenePhase == .active`: fetch `/v2/today`; if `digest.available` and `UserDefaults digestDismissedDay != today.day` → fetch `/v2/digest` and present full-screen. "Start my day" sets `digestDismissedDay = day`. The date label on Today re-opens it any time without touching the flag.

### Sleep
- Day back/forward uses `prev_day`/`next_day` (forward disabled when null). Fetch the week once per `end` date. `Remind me` schedules a local notification at `tonight.bed_by − 30 min`. No red action.

### Body
- Shows weight trend/series, activity, vitals as given. `+ Log weight` opens the sheet.
- **Log weight sheet**: prefilled with `weight.latest.kg`. Save: (1) if "Also save to Apple Health" is on, write `HKQuantitySample(.bodyMass)` (§8) and keep its UUID; (2) enqueue `POST /v2/weight` with a new client UUID and `hk_uuid`; (3) dismiss, show the response's weight block (or the cached block plus a `WAITING TO SYNC` mono label when offline).

### Train
- Nothing names a split for the owner ([11 §7.3](11-scoring.md#73-ready-splits)). Above the stats: `FRESH · PUSH · LOWER` (or `ALL SPLITS LOADED`) and a `Start workout` button; the empty state has the same button. Sessions list rows open Session detail; exercise rows there open Exercise detail. `empty: true` → empty state frame.
- **Start choice sheet**: every split from `splits` as an equal row in server order (`FRESH · 3 DAYS` / `NEW`; `LOADED` in steel, still tappable), plus `Empty workout`. None is preselected; the headline is the chosen split's name, else `Workout`. Start on Watch → send `WatchMessage.plan` (21 §6) then `HKHealthStore().startWatchApp(with: HKWorkoutConfiguration(.traditionalStrengthTraining, .indoor))` ([Apple: startWatchApp, iOS 10+](https://developer.apple.com/documentation/healthkit/hkhealthstore/startwatchapp(with:completion:))). On failure (no paired Watch / app not installed) show the inline error and keep Log on iPhone available. `REMEMBER WATCH OR IPHONE` stores `rememberedStart`: tapping a split then starts at once; with no splits the sheet acts on appear. Settings → Training can clear it.

### iPhone workout logging
- Builds a local `LiveSession` (client UUID, title = the split's name or `Workout`, `template` = a Settings split's id, exercises from the split), prefill per exercise from `GET /v2/exercises/:id` (`last_session.sets` for set rows, `next` for the suggestion). Offline: prefill from the cached exercise responses; if none, empty fields.
- Each check tap: append a `LoggedSet` (client UUID, `performed_at` now, kind `normal` or `warmup` for the `W` row), start the rest timer (`targets.effective` rest from `GET /v2/targets`, default 120 s), haptic `.success`, and enqueue `POST /v2/workouts` with the whole session so far (idempotent upsert, [10 §6](10-server-api.md#post-v2workouts--write)).
- Rest timer: driven by a stored end `Date`, rendered with `TimelineView(.periodic(from:by:1))`; `−15S`/`+15S` adjust the end date; `SKIP` clears it.
- Finish: confirm; set `ended_at`; save an `HKWorkout` with `HKWorkoutBuilder` (iOS 12+; see §8) and put its UUID in `hk_workout_uuid`; final `POST /v2/workouts`; navigate to Session detail for the returned id.
- If a Watch session is live (a `WatchMessage.sessionState` arrived in the last 2 minutes), the iPhone shows that session read-only and disables Log on iPhone, to avoid double logging.
- Live session state is persisted to `Application Support/Vitalis/live-session.json` after every change so a crash loses nothing.

### Eat
- Shows `GET /v2/food/day`. Usual button logs `usual_next` items as one `meal_id` with `source: "usual"`. `+ ADD` opens Quick add for that slot.
- Every add: build entries with client UUIDs and one `meal_id`; write HealthKit food correlations (§8); enqueue `POST /v2/food/entries`; show the Undo toast (5 s, design default) and the `JUST NOW` meal from the response.
- Undo: if the outbox item has not been sent, drop it; else enqueue `DELETE /v2/food/meals/:meal_id`. Either way delete the HealthKit objects written for that meal.
- Quick add: `GET /v2/food/quick?slot=`; any plus button logs immediately (same path as above).
- Search: debounce 500 ms, min 3 characters, at most one request in flight (OFF allows only 10 searches/min server-wide, [10 §7](10-server-api.md#get-v2foodsearchqpage--read)). Show `remote` = `rate_limited`/`unavailable` as a mono line `ONLINE SEARCH BUSY · SHOWING YOURS`.
- Describe: `POST /v2/food/describe`; 503 → hide the Describe tile everywhere for this launch and show `DESCRIBE ISN'T SET UP ON YOUR SERVER`. Steppers pick a `portion_options[].factor`; the app shows `kcal × factor` rounded (display of a server-provided option). Add posts the scaled items with `estimate: true`.
- Scan: `DataScannerViewController` (VisionKit, iOS 16+, [Apple docs](https://developer.apple.com/documentation/visionkit/datascannerviewcontroller)) with barcode symbologies EAN-8, EAN-13, UPC-E; `NSCameraUsageDescription`. On a code → `GET /v2/food/barcode/:code`. Not found → options: Photograph the label (Vision `VNRecognizeTextRequest`, then a prefilled manual form the owner confirms; the app extracts only the four numbers kcal/protein/carbs/fat per serving by matching those words, and the owner corrects them), Describe it, Type the numbers. The confirmed item is saved with `PUT /v2/food/barcode/:code` and logged.

### Setup (first run)
1. Welcome → 2. Connect: validate URL (`ServerSettings`), `TokenStore.save`, `GET /v2/sync/status`. Continue only when 200 **and** `token.can_write`. Errors inline: invalid URL, unreachable, 401 (`TOKEN REJECTED`), `can_write` false (`THIS TOKEN CAN'T LOG WORKOUTS OR FOOD`). → 3. Health access: `requestAuthorization(toShare:read:)` with the share types in §8 plus existing read types. → 4. Reading your history: progress from `SyncEngine.snapshot()`; percent = position of the current page's newest sample date between the oldest sample date seen and now (design default; HealthKit gives no total count). `Set targets while this runs` continues to step 5 while backfill runs. → 5. Targets: `GET /v2/targets` `suggested`; editing a row then Finish sends `PUT /v2/targets` with the values shown.
- Setup is complete when a token is saved and step 5 finished; stored as `UserDefaults setupCompleted = true`. Clearing the token returns to step 2.

- **One Start (25 Oct, owner: no Watch-or-iPhone choice)**: the start sheet has a single **Start workout**. The phone mints the workout id, sends the plan with it (`WatchPlan.session_id`) and opens the Watch app, which records Health under that id; the phone logger opens joined to it. If the Watch can't be opened, the phone owns the workout. A joined workout whose Watch never sent a copy is finished by the phone. The remembered Watch/iPhone choice is gone.
- **Shared workout (25 Oct)**: while the Watch logs a workout, the start sheet offers **Join Watch workout** instead of Log on iPhone. The phone adopts the Watch session's id, title and start, shows the Watch's sets as read-only rows (refreshed from each durable `.session` transfer), and logs its own sets beside them, in time order. Each device posts only its own sets under the same `client_id`; a joined phone body omits title, template, `ended_at` and the Health link, which are the Watch's. After each phone set the whole phone list goes to the Watch (`phone_sets`, durable `transferUserInfo`). The Watch alone records the Health workout and ends it; **Leave** on the phone only stops logging there, and a record with `ended_at` closes the joined session. Phone sets can be edited (weight, reps) but not deleted, so no deletion travels between devices.
- **Finish**: a session still titled `Workout` asks for a name first (`Save and finish` / `Finish without a name`); named workouts become history splits.

- **Eat goal prompt**: while `is_set.goal` is `false`, Eat shows `YOUR GOAL` with Set my goal (opens the Goal sheet) above the day. Servers without the flag don't prompt.

### Settings and Sync
- Settings rows: SERVER (host, token in Keychain, last sync → Sync screen), TARGETS (from `GET /v2/targets`, edit → `PUT`; **Goal** row → Goal sheet: Lose / Maintain / Gain + target weight, saved directly with `PUT /v2/targets {goal, goal_weight_kg}`, then the resulting kcal with its reasons from `plan`: maintenance and where it came from, the daily deficit or surplus and kg a week, weeks to the target, and when it starts adapting; lose needs a target below the current trend, gain above), TRAINING (weekly sets range, default rest, crown step, Splits → list + editor: name and the muscles it needs fresh, via `GET /v2/splits` and direct `PUT`/`DELETE /v2/splits/:id` so a 409 duplicate name shows in the sheet; remembered start choice), Acknowledgements (Archivo OFL, Azeret Mono OFL, muscle map MIT), Reset local export state (existing), Replace token, version.
- Sync screen: existing `SyncView` content restyled, plus the Outbox (§5.3) count and Watch sets held count.
- Token rejected (last exporter upload or any API call returned 401): frame `25-state-sync-token-rejected.png`, counts = exporter pending batches + outbox items + Watch sets not yet posted. `Replace token` → secure field → `TokenStore.save` → `syncNow()` + outbox flush. Record `firstAuthFailureAt` in `UserDefaults` for the `SINCE …` label; clear it on the next 200.

## 5. Networking, cache and outbox

### 5.1 VitalisAPI (VitalisKit)

- `public struct VitalisAPI: Sendable` built on the same request path as `HTTPAPIClient` (reuse the `NoRedirects` delegate and Keychain token; move the shared request function into one place). One `URLSession` per client instance (not per request) with `URLSessionConfiguration.ephemeral`, 30 s request timeout for reads, 60 s for writes.
- One method per endpoint in [10 §9](10-server-api.md#9-route-summary), returning `Codable` models whose property names map the JSON keys exactly (`JSONDecoder.keyDecodingStrategy = .convertFromSnakeCase`). Models live in `VitalisKit/APIModels/*.swift`; dates decode from ISO 8601 with offset.
- Reads send `If-None-Match` from the cache; a 304 returns the cached body.
- Errors: `enum APIError { unauthorized, scope, notFound, invalid(String), rateLimited, unavailable, server(Int), transport(URLError), decoding }` built from the status and the `code` field.

### 5.2 ResponseCache

- One JSON file per (endpoint, normalised query) under the shared container (App Group when available, else `Application Support/Vitalis/cache/`), storing `{ etag, fetched_at, body }`. Complete file protection `completeUntilFirstUserAuthentication`, excluded from backup (same as the exporter's files, `apple/README.md` → Persistence).
- Keep the last 30 days of day-keyed responses; prune on launch.
- The whole cache is deleted on "Reset local export state" and on token replacement to a different server.

### 5.3 Outbox (durable writes)

- An actor `Outbox` in VitalisKit persisting an ordered JSON-lines file of pending requests: `{ id, method, path, body, created_at, attempts, last_error }`. Every write in the app goes through it, including the iPhone workout upserts and the Watch sets relayed by the phone.
- Flush: on enqueue, on foreground, on network path change to satisfied (`NWPathMonitor`), after `syncNow()`. Sequential, in order. 2xx → remove. 401/403 → stop and surface the token state. 409/422 → remove, keep in a `failed.jsonl` shown on the Sync screen with the server message (the request will never succeed as is). 429/5xx/transport → keep; retry with backoff 5 s, 30 s, 2 min, 10 min (cap).
- All bodies carry client UUIDs, so a replay after a crash is safe (server idempotency, [10 §6](10-server-api.md#post-v2workouts--write), [10 §7](10-server-api.md#post-v2foodentries--write)).
- Pending items are visible: Eat shows unsent entries under their meal with a mono `WAITING TO SYNC` label; numbers at the top stay the server's (no client recomputation).

## 6. Offline, cache and stale rules

| Situation | Rule |
|---|---|
| Launch / foreground | Render the cached body immediately (no spinner), then revalidate. |
| Cached body older than 15 min and the refresh fails (offline) | Keep showing it; StatusRow label `OFFLINE · UPDATED HH:MM` (steel). |
| No cache and offline | Loading layout with `–` values and the body line "Connect to your server to see today." |
| **Sync stale** | `freshness.last_sync` older than **12 hours** (design default), or the exporter's last upload failed and its last success is older than 12 hours. Show `24-state-today-sync-stale.png`: StatusRow `LAST SYNC <DAY>` in `watch`, the stale section, **Fix sync** as the screen's one red action (the verdict action becomes a secondary button). |
| Stale cause copy | 401 → "Your server stopped accepting uploads." · transport/unreachable → "Your phone can't reach your server." · 5xx → "Your server is having trouble." · protected data unavailable → "Unlock your phone to sync." · no failure recorded (phone just hasn't synced) → "Your phone hasn't synced since <day>." Body for all: "Everything is safe on this phone until it's fixed." |
| `recovery.status = calibrating` | Recovery number `–`, mono `NO RECOVERY SCORE`, body = `recovery.reason` ("Needs 9 more nights"). Other blocks render. |
| `recovery.status = missing` | Same layout, body = `recovery.reason`. |
| Data for a day missing (`null`) | `–` in steel. Never 0. |

## 7. States per screen

Every screen implements: loading (labels, `–` values, no shimmer), loaded, cached/offline, empty (where a frame exists), error (cached + mono error label; no cache → one body line and a `Try again` secondary button). Specific empty states: Train `empty: true`, Eat `empty: true`, Sleep `has_night: false` ("No sleep recorded"), Body weight with no readings ("No weight yet" + `+ Log weight`). HealthKit denied: detect "no samples ever" from `/v2/sync/status` `types` being empty after setup, show "Allow Health access" with a button opening the Health settings (`x-apple-health://` is not public; open `UIApplication.openSettingsURLString`).

## 8. HealthKit write-back

Share types to add to `AppModel.authorize()` (`toShare`), plus `NSHealthUpdateUsageDescription` in `Vitalis/Info.plist`, and update `apple/README.md` (which currently says no write access is requested):

| Data | What the app writes | When |
|---|---|---|
| Weight | `HKQuantitySample(.bodyMass)` in kg, metadata `HKMetadataKeyWasUserEntered = true` ([Apple](https://developer.apple.com/documentation/healthkit/hkmetadatakeywasuserentered)) | Log weight Save with the toggle on |
| Food | One `HKCorrelation(.food)` per entry ([food correlation, iOS 8+](https://developer.apple.com/documentation/healthkit/hkcorrelationtypeidentifier/food)) holding `dietaryEnergyConsumed` ([iOS 8+](https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/dietaryenergyconsumed)), `dietaryProtein`, `dietaryCarbohydrates`, `dietaryFatTotal` samples; metadata `HKMetadataKeyFoodType = name`, `HKMetadataKeyExternalUUID = entry id` | Every food add; deleted on Undo/delete |
| iPhone workouts | `HKWorkout` built with `HKWorkoutBuilder` ([iOS 12+](https://developer.apple.com/documentation/healthkit/hkworkoutbuilder)), activity `.traditionalStrengthTraining`, start/end from the live session. No live heart rate on iPhone: `HKLiveWorkoutBuilder` on iOS needs iOS 26 ([Apple docs list iOS 26.0](https://developer.apple.com/documentation/healthkit/hkliveworkoutbuilder)) and the deployment target is iOS 18 | iPhone Finish |
| Watch workouts | Written on the Watch ([21 §4](21-watch-app.md#4-workout-session-healthkit)) | Watch End |

- Write failures never block the server write: the server entry is the source of truth; log the HealthKit error on the Sync screen.
- These samples come back to the server through the existing exporter as raw samples. Weight is deduped ([12 §2.3](12-data-model.md#23-manual-weight-projection)); dietary samples are ignored by Fuel ([11 §8.2](11-scoring.md#82-calorie-target)); workouts link to sessions by `hk_workout_uuid`.

## 9. Widgets and the App Group

- New widget extension target `VitalisWidgets` (iOS). Families: `systemSmall`, `systemMedium`, `accessoryCircular`, `accessoryRectangular` (frame `29-widgets-home-lock.png`).
- Data: after every successful `/v2/today` fetch, the app writes `TodaySnapshot` (a subset of the `/v2/today` body: `day`, verdict band/label/headline, recovery score/band, steps/target, kcal left, protein/target, `pulse`, `freshness.last_sync`, `generated_at`) as JSON into the App Group container and calls `WidgetCenter.shared.reloadAllTimelines()`. The widget only reads that file; it never calls HealthKit or the network. Missing snapshot → `–` values.
- App Group id `group.$(BUNDLE_PREFIX).vitalis` for the app, `VitalisWidgets`, the Watch app and the Watch widget extension. Free-team provisioning of App Groups is unverified ([50 Q2](50-open-questions.md#q2-app-groups-on-the-free-personal-team)); if it fails, ship without widgets and complications (the rest of the app does not depend on the App Group; the cache falls back to the app container).

## 10. Accessibility

- Every number is read with its label and unit ("Recovery 82, ready"); label + value pairs use `.accessibilityElement(children: .combine)`.
- Colour never carries meaning alone: arrows (↑ ↓) and words (`READY`, `18 MIN LATE`) do.
- Dynamic Type: test `.xxxLarge` and `.accessibility2`; layouts reflow (rows wrap, two-column blocks stack); hero numbers stop growing at `.accessibility1`. The Today layout scrolls at large sizes with the primary button pinned.
- PulseLine and MuscleMap: PulseLine is hidden from VoiceOver; MuscleMap is one element whose label lists muscles by heat ("Fresh: quadriceps, hamstrings. Loaded: chest.").
- Hit targets ≥ 44 pt (the 36 pt day-nav buttons get a 44 pt content shape).
- Haptics: set logged, Undo shown, rest end. None on navigation.

## 11. Testing

- `VitalisTests`: decoding tests for every endpoint model using the JSON examples in [10-server-api.md](10-server-api.md) saved as fixtures under `VitalisTests/Fixtures/api/*.json`; Outbox ordering/retry/idempotency tests with a stub `URLProtocol`; ResponseCache ETag/304 tests; deep-link routing tests.
- Previews for every screen state named above, from fixtures only (no HealthKit, no network in previews).
- Build commands: `apple/README.md` → "Build and test on a Mac".
