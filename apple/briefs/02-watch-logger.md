# 02 · Watch logger (watchOS)

Implements (all @2x frames: 416×496 px = **208×248 pt**; halve every number in the HTML):
- **V · Watch start** `kNA_vRK_cy`
- **V · Watch set entry** `pCSw4PpAhl`
- **V · Watch rest** `AIJAljEgAy`
- **V · Watch summary** `k_nhjKQwwv`
- **V · Watch face** `9KeK3X1BI1` (complication content; see below)

Live metrics, next-exercise handoff, add exercise and end workout have **no approved V frame**; they are specified in words in [spec/21-watch-app.md §2.4–2.7](../../spec/21-watch-app.md#24-live-metrics-no-frame--specify-in-words). Build them with the same tokens and flag them for design review. (Pre-V frames "J2 · Watch · …" show the intent only; do not copy their style.)

**Canonical behaviour and data: [spec/21-watch-app.md](../../spec/21-watch-app.md).** This brief keeps the visual measurements. The Watch never calls the server and never computes scores; prefill, the due template, settings and session heat come from the server through the phone (`WatchPack`, `result` messages).

Target: `VitalisWatch` (existing single-target watch app, watchOS 11, embedded in `Vitalis`). Uses `VitalisUI` (tokens, fonts, PulseLine watch variant, MuscleMap) and `VitalisKit` (shared models).

## Decisions this brief rests on

- Logging stays **manual**: pick an exercise, the muscle map lights from the catalog's muscles. Automatic exercise recognition is dropped (decision log).
- Workouts can also be logged on the iPhone (03). Both write the same set model.
- Watch logging must work with no phone and no network ("Watch logging still works offline" in `Z6akLUWcKH`).
- Native feel: corner/edge buttons, bone numbers, red only for the line, the action and now; no boxed cards.

## Shared watch layout

- Screen corner radius 44 pt (frame 88 px). Background `ground`.
- Top row: MonoLabel 11 pt left (context: `VITALIS`, `SQUAT · 2/4`, `SAVED` in `pulse`), time right (system time; do not draw your own if the system shows it — same rule as the phone StatusRow). Top padding 15, sides 22–23 pt.
- Primary button: 33 pt tall, radius 12 pt, `pulse` fill, Action 17 pt black. Sides 22 pt (start) or 28 pt (set entry), 13 pt from the bottom on set entry.
- Digital Crown, double tap and the side button follow system behaviour.

## Screen: Start — `kNA_vRK_cy`

- MonoLabel `FRESH · 6 DAYS` in `good` (days since the suggested group was last trained).
- Headline 54 pt, the suggested workout name ("Legs").
- PrimaryButton **Start**, 8 pt below the headline block.
- Below, rows 35 pt tall with a 1 pt `rule` on top: Headline 17 pt left ("Repeat push"), MonoLabel right (`THU`, the day it was last done). Scrollable list of alternatives: repeat last sessions, then "Choose exercises".
- **Suggestion (decided, server):** the due template, its exercise list and `days_since` come from `GET /v2/training` → `due`, relayed in `WatchPack.due` ([spec/11 §7.2–7.3](../../spec/11-scoring.md#72-templates-v1-default)). The Watch shows it; it does not pick.
- Started from the iPhone (`HKHealthStore.startWatchApp(with:)` from 03's start-choice sheet): skip this screen and open set entry for the plan sent over WatchConnectivity.

## Screen: Set entry — `pCSw4PpAhl`

- Top: MonoLabel `<EXERCISE> · <SET>/<PLANNED>` (`SQUAT · 2/4`).
- **Weight**: Number 75 pt (`100`), MonoLabel 12 pt `KG`, centred, 10 pt below the top row.
- **Reps**: Headline 25 pt (`6 REPS`), with MonoLabel 10 pt `LAST 97.5` (last time's weight for this set).
- PulseLine (watch variant) at y 175 pt, x 22…186 pt: one dip per set already logged this exercise, now-dot after the last dip, dotted to the right edge.
- PrimaryButton **Log set** pinned at the bottom.

Interaction:
- Two focusable fields: weight (default focus) and reps. Tap a field to focus it; the focused field gets a 1.5 pt `bone` underline (design default; no frame shows focus).
- **Crown edits the focused field**: weight in **2.5 kg** steps, reps in steps of 1, with haptic detents:
  ```swift
  .focusable()
  .digitalCrownRotation($weight, from: 0, through: 500, by: settings.crownWeightStep,   // 2.5 default
                        sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: true)
  ```
  The step is the server target `crown_step_kg` (default 2.5 kg, edited in Settings → Training), relayed in `WatchPack.settings`. The 0…500 bounds are a sanity clamp, not a product value.
- **Prefill**: set 1 from the server's `next` suggestion (`GET /v2/exercises/:id` via `WatchPack.exercises[id].prefill.next`), falling back to last session's set 1; set n > 1 from the previous logged set in this session; never done → empty fields with focus on weight.
- **Log set**: tap, or **double tap** where supported: `.handGestureShortcut(.primaryAction)` on the button (Apple Watch Series 9 / Ultra 2 and later; elsewhere tapping is the only path). On log: success haptic (`WKInterfaceDevice.current().play(.success)`), the set is written to the local queue, a new dip appears on the line, then the rest timer opens.
- Warm-up sets: long-press Log set (0.5 s) → "Log as warm-up" (design default). Warm-ups never count toward volume, freshness or records (server rule).
- Swipe left: live metrics (heart rate, elapsed, active kcal) from the workout builder; specified in [spec/21 §2.4](../../spec/21-watch-app.md#24-live-metrics-no-frame--specify-in-words).

## Screen: Rest — `AIJAljEgAy`

- MonoLabel `REST` centred, 25 pt from the top.
- Number 70 pt countdown (`1:24`).
- MonoLabel `NEXT`, then Headline 20 pt next set ("Squat 100 kg · 6").
- Bottom row (21 pt from the bottom, 27 pt sides): `−15` and `+15` (MonoLabel in `bone`) at the corners, `TAP TO SKIP` (MonoLabel 9 pt) centred.
- **Progress around the screen edge**: a rounded rectangle inset 4 pt, corner radius 40 pt, stroke 3 pt. Track in `rule`; remaining time in `pulse`, round caps. The red arc **starts at top centre and runs clockwise**, its length = remaining / total (the frame shows 84 s of 120 s = 70 %). Build a custom `Shape` whose path starts at top centre so `.trim(from: 0, to: remaining)` works; animate with `.linear` each second.
- Duration: the server target `rest_s` (default 120 s; Settings → Training edits it via `PUT /v2/targets`), relayed in `WatchPack.settings`. One rest duration for all exercises in v1.
- Tap anywhere → skip to set entry. ±15 adjust the remaining time. At zero: haptic (`.notification`), then set entry with the next set prefilled.
- The rest timer must keep time while the wrist is down: drive it from the workout session's elapsed clock (`TimelineView(.periodic(from:by: 1))` + start date), not from a `Timer`.

## Next-exercise handoff

After the planned sets of an exercise, show the next exercise instead of set entry: MonoLabel `NEXT · <n>/<total>`, Headline 32 pt exercise name, MonoLabel last time (`LAST 95 × 8`), MuscleMap (front or back, whichever shows its primary muscles) at 120 pt with its muscles at heat 4, PrimaryButton **Start**. Crown scrolls to skip to a later exercise. No V frame: build per [spec/21 §2.5](../../spec/21-watch-app.md#25-next-exercise-handoff-no-frame) and flag for design review.

## Add exercise

From set entry or handoff, swipe up (or "+" corner button) → list: exercises in the current template not done yet, recent exercises, then search (dictation / scribble). Selecting one inserts it as next. Exercises come from the catalog the phone sends (see Catalog). No V frame: build per [spec/21 §2.6](../../spec/21-watch-app.md#26-add-exercise-no-frame) and flag for design review.

## End workout and summary — `k_nhjKQwwv`

- End: side-swipe to a controls page (**End**, **Pause**) like the system Workout app; End asks once ("End workout?" with End / Resume). No V frame: build per [spec/21 §2.7](../../spec/21-watch-app.md#27-end-workout-no-frame) and flag for design review.
- Summary: top row MonoLabel `SAVED` in `pulse`. MuscleMap both views at 145 pt, 2 pt below the top row. Bottom block (15 pt from the bottom, 23 pt sides): Headline 32 pt workout name ("Legs"), MonoLabel `61 MIN · 16 SETS · ` + `PR` in `pulse` when a record was set.
- Summary heat = **this session's load**, computed by the server ([spec/11 §7.4](../../spec/11-scoring.md#74-session-heat-watch-summary-session-detail)) and relayed in the `result` message after the phone posts `POST /v2/workouts`. Until it arrives, show catalog lighting (primary 4, secondary 3) with `SYNCING` instead of `PR`.
- PR: from the server response's `prs` (Epley e1RM above every earlier best; rep PRs at the same weight do not count in v1).
- Done → back to Start.

## Watch face — `9KeK3X1BI1`

watchOS does not allow custom watch faces. Treat the frame as the content spec for **WidgetKit complications** in a new watch widget extension target (`VitalisWatchWidgets`):

| Family | Content (from the frame) |
|---|---|
| `accessoryRectangular` | PulseLine (widget variant) + Number recovery (`78`) + MonoLabel `READY` in band tint + steps |
| `accessoryCircular` | Number recovery + `READY` |
| `accessoryCorner` | recovery number, gauge = recovery / 100 |
| `accessoryInline` | `78 READY · 3,206 STEPS` |

Tap opens the watch app on Start. Data: `TodaySnapshot` (01) sent from the iPhone with `WCSession.transferCurrentComplicationUserInfo` and stored in the watch App Group container; the extension reads that file. Watch App Group: unverified on the free team ([spec/50 Q2](../../spec/50-open-questions.md#q2-app-groups-on-the-free-personal-team)). Rendering mode: in tinted faces the `pulse` colour may be replaced by the system tint; use `widgetAccentable()` on the line and number only.

## Workout session (HealthKit)

- On Start: `HKWorkoutSession` with `HKWorkoutConfiguration(activityType: .traditionalStrengthTraining, locationType: .indoor)` and `HKLiveWorkoutBuilder` with `HKLiveWorkoutDataSource`. This keeps the app frontmost-capable, collects heart rate and active energy, and keeps the rest timer alive.
- Request HealthKit authorisation on the watch: share `HKObjectType.workoutType()`, read heart rate and active energy. Add `NSHealthShareUsageDescription` and `NSHealthUpdateUsageDescription` to `VitalisWatch/Info.plist`, and the `workout-processing` background mode.
- On End: `endCollection`, `finishWorkout`. The saved `HKWorkout` reaches the iPhone through Health sync and is exported by the existing `SyncEngine` as a `workout` sample. Store its UUID on the local session as `hkWorkoutUUID` (server field `hk_workout_uuid` in the documented workout shape).
- Sets are **not** HealthKit samples. They travel separately (below).
- Pause / resume map to `session.pause()` / `resume()`; rest does not pause the session.
- Crash recovery: `HKHealthStore.recoverActiveWorkoutSession` on launch; restore the in-memory session from the local queue.

## Local storage and offline queue (watch)

One JSON file per session, written atomically before the UI confirms a log (decided, [spec/21 §5](../../spec/21-watch-app.md#5-local-store-offline-queue)). The canonical models are in spec/21 §5; the sketch below is superseded where it differs.

```swift
struct LoggedSet: Codable, Sendable, Identifiable {
    var id: UUID                    // client id; also the server set id (idempotent)
    var sessionID: UUID             // session client_id
    var exerciseID: String          // catalog id, e.g. "barbell-squat"
    var weightKg: Double
    var reps: Int
    var kind: Kind                  // .working, .warmup
    var performedAt: Date
    var tzOffsetMin: Int
}
struct WorkoutSessionRecord: Codable, Sendable {
    var id: UUID                    // client_id
    var title: String
    var startedAt: Date; var endedAt: Date?
    var tzOffsetMin: Int
    var hkWorkoutUUID: UUID?
    var setIDs: [UUID]
    var state: State                // .live, .ended, .deliveredToPhone, .ackedByPhone
}
```

Field names follow the server's `log_sets` / documented `POST /v2/workouts` input (`docs/api.md`, `docs/native-sync.md`).

## Transfer to iPhone

- Channel: `WCSession.default.transferUserInfo(_:)` — queued, survives app termination, delivered in order when the phone is reachable.
- Payload: one message per change: `{"type": "sets", "session": WorkoutSessionRecord, "sets": [LoggedSet]}`. Send each set as soon as it is logged (so the phone has it even if the watch dies), and the session again on End.
- **Idempotent**: ids are client UUIDs; the phone upserts by id, so re-sends are harmless.
- **Keep until acked**: `session(_:didFinish:error:)` on the watch only means delivered. The phone, after persisting, sends back `{"type": "ack", "setIDs": [...], "sessionID": ...}` via `transferUserInfo`. Only then may the watch mark records `ackedByPhone` and prune them (keep acked sessions 14 days, then delete; never delete an un-acked session).
- Phone → watch: plan from the start-choice sheet (`{"type": "plan", ...}`), freshness snapshot for the Start suggestion, settings (rest, crown step), catalog updates, complication data.
- **Phone → server (decided):** the phone puts each session into its Outbox as a `POST /v2/workouts` body ([spec/10 §6](../../spec/10-server-api.md#post-v2workouts--write), task S-15), acks the Watch after the Outbox write, and relays the response's `session.heat` and `prs` as a `result` message. Held sets show in Settings → Sync as `WATCH SETS HELD` (frame `l4ps-S20fp`).

## Catalog

The Watch picker needs the exercise catalog offline. The server's catalog is free-exercise-db (public domain) plus custom exercises, with ids like `barbell-squat` and primary/secondary muscles. The phone fetches `GET /v2/exercises` (task S-14, ETag-cached) and sends the full list with `transferFile` when it changes; prefill for the due and recent exercises travels in `WatchPack` ([spec/21 §6](../../spec/21-watch-app.md#6-transfer-to-iphone-and-the-server)).

## Signing and device caveats

- The Watch build needs a physical Watch registered to the free team (see README). Until then, test in the watchOS simulator: HealthKit workout sessions run there with simulated data; the Crown is simulated with the mouse wheel; double tap cannot be tested.
- HealthKit on the watch needs the entitlement in `VitalisWatch.entitlements` (present) and the share/read usage strings (to add).
- Background mode `workout-processing` is required or the session stops when the wrist drops.

## Acceptance checklist

- [ ] Start, set entry, rest and summary match `kNA_vRK_cy`, `pCSw4PpAhl`, `AIJAljEgAy`, `k_nhjKQwwv` on a 46 mm simulator (208×248 pt) with fixture data.
- [ ] Crown changes the focused field: weight by 2.5 kg per detent with a haptic, reps by 1; changing the Settings step to 1.25 changes the detent.
- [ ] Set 1 prefills from last time; set 2+ from the previous set; new exercise starts empty.
- [ ] Log set works by tap; double tap triggers it on a supported device (device test).
- [ ] Rest ring starts at top centre, shrinks clockwise, stays correct after wrist-down for 60 s (device or simulator with screen off).
- [ ] ±15 and tap-to-skip work; zero triggers the haptic and the next prefilled set.
- [ ] One dip per logged set on the set-entry line.
- [ ] Killing the watch app mid-workout loses no set: relaunch recovers the session and every logged set.
- [ ] With the phone unreachable (airplane mode), 10 sets log; reconnecting delivers all of them once; the phone shows each set once; the watch prunes only after the ack.
- [ ] The finished `HKWorkout` appears in Health on the phone and in the exporter's next batch.
- [ ] Summary heat follows the session-load rule; PR shows only when the Epley estimate beats the stored best.
- [ ] Complications render the snapshot in rectangular, circular, corner and inline families.
- [ ] Previews for every watch screen, including first-ever workout (no prefill) and phone unreachable (sets queued).
