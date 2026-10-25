# 21 · Apple Watch app

A strength logger that works with no phone and no network, plus complications. It never calls the server: the iPhone relays everything (sets up to `POST /v2/workouts`, prefill and Today data down). It never computes scores; its only numbers are what the owner logs and what the phone sends.

Visual measurements: [apple/briefs/02-watch-logger.md](../apple/briefs/02-watch-logger.md) (frames are @2x: 416×496 px = 208×248 pt; halve every HTML number). Tokens and the watch variants of PulseLine/MuscleMap: [30-design-system.md](30-design-system.md).

## 1. Starting point

- Target `VitalisWatch` exists (`apple/project.yml`): watchOS 11.0, single-target SwiftUI app embedded in `Vitalis`, depends on `VitalisKit`. Its only screen says "Workouts coming soon" (`VitalisWatch/VitalisWatchApp.swift`).
- `VitalisWatch/VitalisWatch.entitlements` already has `com.apple.developer.healthkit`. `VitalisWatch/Info.plist` lacks HealthKit usage strings and background modes (add them, §4).
- Signing: the Watch build fails until a physical Watch is registered to the free team (`apple/briefs/README.md` → Signing caveats). Develop in the watchOS simulator until then.

## 2. Screens and flows

| Screen | Frame | Data source |
|---|---|---|
| Start | `spec/design/30-watch-start.png` | `WatchPack.splits` + `WatchPack.recentSessions` |
| Set entry | `spec/design/31-watch-set-entry.png` | Live session + `WatchPack.exercises[id].prefill` |
| Rest | `spec/design/32-watch-rest.png` | Live session; `WatchPack.settings.rest_s` |
| Summary | `spec/design/33-watch-summary.png` | Live session; `session.heat` + `prs` relayed from the server response |
| Face / complications | `spec/design/34-watch-face-complications.png` | `TodaySnapshot` (20 §9) |
| Live metrics | **no approved frame** | `HKLiveWorkoutBuilder` statistics |
| Next-exercise handoff | **no approved frame** | Plan + prefill |
| Add exercise | **no approved frame** | `WatchPack.catalog` |
| End workout | **no approved frame** | Live session |

Flow: Start → (a split row) → Set entry → (Log set) → Rest → (timer ends / tap) → Set entry for the next set … → after the planned sets of an exercise → Next-exercise handoff → Set entry … → End → Summary → Done → Start. Started from the phone (`startWatchApp`), the app skips Start and opens Set entry for the plan the phone sent; with no plan it stays on Start.

### 2.1 Start (frame 30)
- Headline 54 pt `Workout`; nothing names a split ([11 §7.3](11-scoring.md#73-ready-splits)).
- One row per split in pack order (35 pt, rule on top): the split name, right label `FRESH · <N> DAYS` / `NEW` in `good` when ready, `LOADED` in steel when not (still tappable). Tapping starts a session titled with the split's name; a split with no exercises opens Add exercise.
- Then `Repeat <title>` for up to 3 recent sessions whose title no split has (`recentSessions`, right label = weekday), then `Choose exercises` (opens Add exercise to build a session from scratch).
- No pack yet (fresh install, phone never reachable): headline `Workout` and `Choose exercises` only.

### 2.2 Set entry (frame 31)
- Top label `<EXERCISE> · <SET>/<PLANNED>`. Weight Number 75 pt + `KG`; reps Headline 25 pt `6 REPS`; small label `LAST 97.5` (last time's weight for this set number).
- MuscleMap is not on this screen in the frame; the target muscles of the current exercise are named in the top label only. (The decision log's "target muscles glowing" is satisfied by the handoff screen.)
- PulseLine (watch variant): one dip per set already logged for this exercise, now-dot after the last dip, dotted to the edge.
- **Crown** edits the focused field (weight focused by default; tap reps to focus): `.digitalCrownRotation(_:from:through:by:sensitivity:isContinuous:isHapticFeedbackEnabled:)` ([watchOS 6+](https://developer.apple.com/documentation/swiftui/view/digitalcrownrotation(_:from:through:by:sensitivity:iscontinuous:ishapticfeedbackenabled:))) with `by: settings.crown_step_kg` (default 2.5) for weight, 1 for reps, haptic detents on, bounds 0…500 kg and 0…100 reps. Focused field: 1.5 pt bone underline (design default; no frame shows focus).
- **Prefill**: set 1 of an exercise = `prefill.sets[0]` from the pack (the server's last session sets) or the server's `next` suggestion when `use_suggestion` is on (default on: weight/reps from `next.weight_kg`/`next.reps`); set n > 1 = the previous logged set in this session. Never done → empty fields, weight focused.
- **Log set**: tap, or double tap via `.handGestureShortcut(.primaryAction)` ([iOS 18 / watchOS 11](https://developer.apple.com/documentation/swiftui/view/handgestureshortcut(_:isenabled:)); hardware support is device-dependent). On log: write the set durably (§5) **before** any UI change, play `.success` (`WKInterfaceDevice.play(_:)`), add a dip, send to phone (§6), open Rest.
- **Warm-up**: long-press Log set (0.5 s) → `Log as warm-up`. Warm-ups don't advance the set counter.

### 2.3 Rest (frame 32)
- `REST`, Number 70 pt countdown, `NEXT` + Headline 20 pt next set (`Squat 100 kg · 6`), corners `−15` / `+15`, centre `TAP TO SKIP`.
- Progress drawn around the screen edge: rounded rect inset 4 pt, corner radius 40 pt, 3 pt stroke; track `rule`, remaining `pulse` with round caps, starting at top centre and running clockwise; length = remaining / total. Build a custom `Shape` whose path starts at top centre so `.trim(from: 0, to: fraction)` works.
- Duration = `settings.rest_s` (server target, default 120 s). Time is computed from a stored end `Date` and rendered with `TimelineView(.periodic(from:by: 1))`, so it stays correct after wrist-down (the workout session keeps the app running, §4).
- At zero: `.notification` haptic, then Set entry with the next set prefilled.

### 2.4 Live metrics (no frame — specify in words)
- Reached by swiping left from Set entry or Rest (vertical `TabView` page). Black ground, top label `LIVE`, three stacked readings with Number 32 pt values and MonoLabel captions: `BPM` (current heart rate from `HKLiveWorkoutBuilder.statistics(for: heartRate).mostRecentQuantity`), `ELAPSED` (`builder.elapsedTime`, `m:ss` then `h:mm:ss`), `ACTIVE KCAL` (`activeEnergyBurned` sum, rounded). No red, no button. Missing values show `–`.

### 2.5 Next-exercise handoff (no frame)
- Shown after the last planned set of an exercise (planned = sets in `prefill.sets` working count, default 3 when unknown) instead of Set entry.
- Top label `NEXT · <n>/<total>`; Headline 32 pt exercise name; MonoLabel `LAST 95 × 8` (from prefill) or `NEW`; MuscleMap (front or back, whichever side shows more of its primary muscles) at 120 pt with the exercise's primary muscles at heat 4 and secondary at heat 3 (catalog lighting: display of catalog data, not a score); PrimaryButton **Start**.
- Crown scrolls to later exercises in the plan; `Skip` text button (MonoLabel, bone) moves the exercise to the end.

### 2.6 Add exercise (no frame)
- Reached from the Start screen (`Choose exercises`), from a `+` corner button on Set entry, or from the handoff.
- List rows (35 pt, rule on top, Headline 17 pt name + MonoLabel 10 pt equipment): first the plan's exercises not done yet, then `recent` (last 20 exercise ids used), then a `Search` row opening the system text input (dictation/Scribble); matches are ranked by the same rule as the server's `findExercises()` scoring on `name` and `aliases` from the pack catalog (string matching on catalog data, no scores). Selecting inserts the exercise as next and opens Set entry.

### 2.7 End workout (no frame)
- Swipe right from Set entry to a controls page (like the system Workout app): two 44 pt-tall buttons stacked, **End** (`pulse` fill, Action 17 pt black) and **Pause** / **Resume** (secondary ring). End asks once: Headline 20 pt `End workout?`, buttons End (red) and Resume.
- On End: `session.end()`, `builder.endCollection(at:)`, `builder.finishWorkout()`; store the returned `HKWorkout.uuid` as `hkWorkoutUUID`; mark the session `ended`; send it to the phone (§6); show Summary.

### 2.8 Summary (frame 33)
- Top label `SAVED` in `pulse`, MuscleMap both views at 145 pt, Headline 32 pt title, label `61 MIN · 16 SETS` + ` · PR` in `pulse` when the server reported a PR.
- Heat = server `session.heat` from the relayed `POST /v2/workouts` response ([10 §6](10-server-api.md#post-v2workouts--write)). Until it arrives (phone away), show catalog lighting (primary muscles of logged exercises 4, secondary 3) with a small `SYNCING` label instead of `PR`. When the response arrives while the summary is open, swap in the server heat and PR.
- Done → Start.

## 3. Complications (frame 34)

watchOS has no custom faces, so the face frame is the content spec for WidgetKit complications in a new watch widget extension target `VitalisWatchWidgets`:

| Family | Content |
|---|---|
| `accessoryRectangular` | PulseLine (widget variant) + recovery score + band label (tinted) + steps |
| `accessoryCircular` | recovery score + band label |
| `accessoryCorner` | recovery score, gauge = score / 100 |
| `accessoryInline` | `82 READY · 3,206 STEPS` |

- Data: `TodaySnapshot` ([20 §9](20-ios-app.md#9-widgets-and-the-app-group)), sent by the phone with `WCSession.transferCurrentComplicationUserInfo(_:)` ([iOS 9+](https://developer.apple.com/documentation/watchconnectivity/wcsession/transfercurrentcomplicationuserinfo(_:))) when `remainingComplicationUserInfoTransfers > 0` ([iOS 10+](https://developer.apple.com/documentation/watchconnectivity/wcsession/remainingcomplicationuserinfotransfers)), else in the next `updateApplicationContext`. The watch app writes it to the watch App Group container and reloads timelines; the extension reads only that file. Missing → `–`.
- Tinted faces: `widgetAccentable()` on the line and the number only.
- Tap opens the app on Start.

## 4. Workout session (HealthKit)

- Start: `HKWorkoutSession` with `HKWorkoutConfiguration(activityType: .traditionalStrengthTraining, locationType: .indoor)` and its `HKLiveWorkoutBuilder` + `HKLiveWorkoutDataSource` (watchOS 5+, [HKLiveWorkoutBuilder](https://developer.apple.com/documentation/healthkit/hkliveworkoutbuilder)). This collects heart rate and active energy and keeps the app running with the wrist down.
- Authorisation on the watch: share `HKObjectType.workoutType()`, read `heartRate`, `activeEnergyBurned`. Add `NSHealthShareUsageDescription` and `NSHealthUpdateUsageDescription` to `VitalisWatch/Info.plist` and `WKBackgroundModes` = `workout-processing`.
- Launched by the phone's `startWatchApp(with:)`: handle the configuration in the app delegate (`WKApplicationDelegate`'s `handle(_:)` overload that receives an `HKWorkoutConfiguration`; attach with `@WKApplicationDelegateAdaptor`), then start the session with the plan from the last `WatchMessage.plan`.
- Pause/Resume map to `session.pause()` / `resume()`. Rest does not pause.
- Crash recovery: on launch call `HKHealthStore.recoverActiveWorkoutSession(completion:)` ([watchOS 5+](https://developer.apple.com/documentation/healthkit/hkhealthstore/recoveractiveworkoutsession(completion:))) and rebuild the in-memory session from the local store (§5).
- Sets are not HealthKit samples; they travel to the phone (§6). The `HKWorkout` reaches the phone through Health sync and is exported by the existing `SyncEngine`; its UUID links it to the session on the server (`sessions.hk_workout_uuid`).

## 5. Local store (offline queue)

- File-based JSON in the watch app's Application Support: one file per session `sessions/<client_id>.json`, written atomically (`Data.write(options: .atomic)`) after every change, before the UI confirms. (Design decision over SwiftData: fewer moving parts, trivially inspectable, and the data is tiny.)
- Models (in `VitalisKit/WatchMessages.swift`, shared with the phone):

```swift
public struct LoggedSet: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID              // client id = server set id (idempotent)
    public var exerciseID: String    // catalog id, e.g. "barbell-squat"
    public var kind: Kind            // .normal, .warmup
    public var weightKg: Double?
    public var reps: Int?
    public var performedAt: Date
    public var deleted: Bool
    public enum Kind: String, Codable, Sendable { case normal, warmup }
}
public struct WorkoutSessionRecord: Codable, Sendable, Identifiable {
    public var id: UUID              // session client_id
    public var title: String
    public var template: String?     // "legs" | "push" | "pull" | nil
    public var source: String        // "watch"
    public var startedAt: Date
    public var endedAt: Date?
    public var tzOffsetMin: Int
    public var hkWorkoutUUID: UUID?
    public var sets: [LoggedSet]
    public var delivery: Delivery    // .pending, .sentToPhone, .ackedByPhone
    public enum Delivery: String, Codable, Sendable { case pending, sentToPhone, ackedByPhone }
}
```

- Retention: keep acked sessions 14 days (for `Repeat …` rows and offline prefill fallback), then delete. Never delete a session that is not `ackedByPhone`.

## 6. Transfer to iPhone and the server

All messages are `Codable` enums encoded to `[String: Any]` via JSON, defined once in `VitalisKit/WatchMessages.swift`:

| Message | Direction | Channel | Content |
|---|---|---|---|
| `session` | watch → phone | `transferUserInfo(_:)` (queued, survives termination, delivered in order; [docs](https://developer.apple.com/documentation/watchconnectivity/wcsession/transferuserinfo(_:))) | the full `WorkoutSessionRecord`. Sent after every logged/edited set and on End. |
| `ack` | phone → watch | `transferUserInfo` | `session_id`, `set_ids` persisted by the phone outbox |
| `result` | phone → watch | `transferUserInfo` | `session_id`, server `session.heat`, `prs` (from the `POST /v2/workouts` response) |
| `pack` | phone → watch | `updateApplicationContext(_:)` (latest state wins; [docs](https://developer.apple.com/documentation/watchconnectivity/wcsession/updateapplicationcontext(_:))) | `WatchPack` (below) |
| `catalog` | phone → watch | `transferFile(_:metadata:)` | full `GET /v2/exercises` JSON when its ETag changes |
| `plan` | phone → watch | `sendMessage` when reachable, else in `pack` | template, exercise ids, `intensity` from the start-choice sheet |
| `sessionState` | watch → phone | `sendMessage` when reachable | `live` / `ended` + session id, so the phone can disable iPhone logging (20 §4) |
| `today` | phone → watch | complication transfer (§3) | `TodaySnapshot` |

`WatchPack` (built by the phone from cached server responses after each successful refresh):

```json
{
  "generated_at": "2026-10-24T09:41:02+05:30",
  "settings": { "rest_s": 120, "crown_step_kg": 2.5 },
  "splits": [ { "id": "lower", "template": "lower", "name": "Lower", "ready": true, "days_since": 6, "exercise_ids": ["barbell-squat", "romanian-deadlift", "leg-press"] },
              { "id": "history:push", "template": null, "name": "Push", "ready": false, "days_since": 1, "exercise_ids": ["barbell-bench-press-medium-grip"] } ],
  "recent_sessions": [ { "title": "Push", "template": "push", "day": "2026-10-22", "exercise_ids": ["barbell-bench-press-medium-grip"] } ],
  "exercises": {
    "barbell-squat": { "name": "Barbell Squat", "primary": ["quadriceps"], "secondary": ["calves","glutes","hamstrings","lower-back"],
                       "prefill": { "sets": [ { "kind": "normal", "weight_kg": 97.5, "reps": 6 } ], "next": { "weight_kg": 100, "reps": 6, "sets": 4 } } }
  },
  "recent_exercise_ids": ["barbell-squat"]
}
```

`exercises` covers every split, the recent sessions' exercises and the 20 most recent exercises, using `GET /v2/exercises/:id` responses (`last_session`, `next`). Keep the encoded pack under 64 KB (design limit; drop the oldest recent exercises first).

Phone side (`Vitalis/Watch/PhoneSessionDelegate.swift`):

1. On `session` userInfo: persist into the Outbox as a `POST /v2/workouts` body ([10 §6](10-server-api.md#post-v2workouts--write)) with `source: "watch"`, replacing any not-yet-sent body for the same `client_id` (latest wins; the server upserts anyway).
2. After the Outbox has durably written it, send `ack` with the set ids. The watch marks `ackedByPhone` only on `ack`; `session(_:didFinish:error:)` on the watch only means "delivered", not "persisted".
3. When the Outbox gets a 200 for that session, send `result`.
4. Held counts (`WATCH SETS HELD 16` on the token-rejected screen) = sets in Outbox `POST /v2/workouts` bodies not yet sent.

## 7. Acceptance (summary; full checklist in the brief)

- Logging 10 sets in airplane mode, then reconnecting, delivers each set exactly once to the server (verify with `GET /v2/training/sessions/:id`), and the watch prunes only after `ack`.
- Killing the watch app mid-workout loses no set; relaunch recovers the HealthKit session and the local file.
- Crown steps follow `crown_step_kg` from the server targets.
- Rest ring is correct after 60 s wrist-down.
- Summary shows server heat and PR once the phone relays the result; `SYNCING` before that.
- Complications render all four families from a fixture `TodaySnapshot`.
