# 02 · Watch logger (watchOS)

Implements (all @2x frames: 416×496 px = **208×248 pt**; halve every number in the HTML):
- **V · Watch start** `kNA_vRK_cy`
- **V · Watch set entry** `pCSw4PpAhl`
- **V · Watch rest** `AIJAljEgAy`
- **V · Watch summary** `k_nhjKQwwv`
- **V · Watch face** `9KeK3X1BI1` (complication content; see below)

Next-exercise handoff, add exercise and end-workout have **no approved V frame**; build them from the rules here with the same tokens, and mark the screens for design review. (Pre-V frames "J2 · Watch · Next exercise handoff", "Add exercise mid-session" and "End workout" show the intent only; do not copy their style.)

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
- **Suggestion rule (TBD)**: the frames show a muscle-group template ("Legs" = squat, Romanian deadlift, leg press, leg curl, calf raise in `3qVL-kZTgZ`) chosen by freshness. Define the templates (Legs / Push / Pull / …), their exercise lists, and the pick rule (proposal: the template whose primary muscles have the highest minimum days-since-trained). Freshness comes from the local set store (synced from iPhone, see Transfer).
- Started from the iPhone (`HKHealthStore.startWatchApp(with:)` from 03's start-choice sheet): skip this screen and open set entry for the plan sent over WatchConnectivity.

## Screen: Set entry — `pCSw4PpAhl`

- Top: MonoLabel `<EXERCISE> · <SET>/<PLANNED>` (`SQUAT · 2/4`).
- **Weight**: Number 75 pt (`100`), MonoLabel 12 pt `KG`, centred, 10 pt below the top row.
- **Reps**: Headline 25 pt (`6 REPS`), with MonoLabel 10 pt `LAST 97.5` (last time's weight for this set).
- PulseLine (watch variant) at y 175 pt, x 22…186 pt: one dip per set already logged this exercise, now-dot after the last dip, dotted to the right edge.
- PrimaryButton **Log set** pinned at the bottom.

Interaction:
- Two focusable fields: weight (default focus) and reps. Tap a field to focus it; the focused field gets a 1.5 pt `bone` underline (**TBD**: focus indicator has no frame; confirm).
- **Crown edits the focused field**: weight in **2.5 kg** steps, reps in steps of 1, with haptic detents:
  ```swift
  .focusable()
  .digitalCrownRotation($weight, from: 0, through: 500, by: settings.crownWeightStep,   // 2.5 default
                        sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: true)
  ```
  The step comes from Settings → Training → Crown weight step (03, default 2.5 kg). The 0…500 bounds are a sanity clamp, not a product value.
- **Prefill**: weight and reps from the previous set of this exercise in this session; for set 1, from the same set number last time this exercise was done (Hevy-style, research note); if never done, empty fields with focus on weight.
- **Log set**: tap, or **double tap** where supported: `.handGestureShortcut(.primaryAction)` on the button (Apple Watch Series 9 / Ultra 2 and later; elsewhere tapping is the only path). On log: success haptic (`WKInterfaceDevice.current().play(.success)`), the set is written to the local queue, a new dip appears on the line, then the rest timer opens.
- Warm-up sets: long-press Log set → "Log as warm-up" (**TBD**: confirm gesture; the iPhone table shows a `W` row). Warm-ups never count toward volume, freshness or records (server rule).
- Swipe left: live metrics (heart rate, elapsed, active kcal) from the workout builder. **TBD**: no V frame; follow the type roles.

## Screen: Rest — `AIJAljEgAy`

- MonoLabel `REST` centred, 25 pt from the top.
- Number 70 pt countdown (`1:24`).
- MonoLabel `NEXT`, then Headline 20 pt next set ("Squat 100 kg · 6").
- Bottom row (21 pt from the bottom, 27 pt sides): `−15` and `+15` (MonoLabel in `bone`) at the corners, `TAP TO SKIP` (MonoLabel 9 pt) centred.
- **Progress around the screen edge**: a rounded rectangle inset 4 pt, corner radius 40 pt, stroke 3 pt. Track in `rule`; remaining time in `pulse`, round caps. The red arc **starts at top centre and runs clockwise**, its length = remaining / total (the frame shows 84 s of 120 s = 70 %). Build a custom `Shape` whose path starts at top centre so `.trim(from: 0, to: remaining)` works; animate with `.linear` each second.
- Duration: Settings → Training → Default rest (03; the Settings frame shows 2:00). Per-exercise rest: **TBD**.
- Tap anywhere → skip to set entry. ±15 adjust the remaining time. At zero: haptic (`.notification`), then set entry with the next set prefilled.
- The rest timer must keep time while the wrist is down: drive it from the workout session's elapsed clock (`TimelineView(.periodic(from:by: 1))` + start date), not from a `Timer`.

## Next-exercise handoff

After the planned sets of an exercise, show the next exercise instead of set entry: MonoLabel `NEXT · <n>/<total>`, Headline 32 pt exercise name, MonoLabel last time (`LAST 95 × 8`), MuscleMap (front or back, whichever shows its primary muscles) at 120 pt with its muscles at heat 4, PrimaryButton **Start**. Crown scrolls to skip to a later exercise. No V frame: **TBD** design review.

## Add exercise

From set entry or handoff, swipe up (or "+" corner button) → list: exercises in the current template not done yet, recent exercises, then search (dictation / scribble). Selecting one inserts it as next. Exercises come from the local catalog cache (see Catalog). No V frame: **TBD** design review.

## End workout and summary — `k_nhjKQwwv`

- End: side-swipe to a controls page (**End**, **Pause**) like the system Workout app; End asks once ("End workout?" with End / Resume). No V frame: **TBD** design review.
- Summary: top row MonoLabel `SAVED` in `pulse`. MuscleMap both views at 145 pt, 2 pt below the top row. Bottom block (15 pt from the bottom, 23 pt sides): Headline 32 pt workout name ("Legs"), MonoLabel `61 MIN · 16 SETS · ` + `PR` in `pulse` when a record was set.
- Summary heat = **this session's load**, not freshness. Frame example: quadriceps, glutes, hamstrings 4; adductors, calves 3; lower back 2. **TBD**: the rule (proposal: primary muscles of exercises done = 4, secondary = 3, muscles with only one secondary set = 2).
- PR: estimated 1RM (Epley, `w × (1 + reps/30)`, 1–12 reps only, server rule) above the best previous for that exercise in the local store. **TBD**: whether a rep PR at the same weight also counts.
- Done → back to Start.

## Watch face — `9KeK3X1BI1`

watchOS does not allow custom watch faces. Treat the frame as the content spec for **WidgetKit complications** in a new watch widget extension target (`VitalisWatchWidgets`):

| Family | Content (from the frame) |
|---|---|
| `accessoryRectangular` | PulseLine (widget variant) + Number recovery (`78`) + MonoLabel `READY` in band tint + steps |
| `accessoryCircular` | Number recovery + `READY` |
| `accessoryCorner` | recovery number, gauge = recovery / 100 |
| `accessoryInline` | `78 READY · 3,206 STEPS` |

Tap opens the watch app on Start. Data: `TodaySnapshot` (01) sent from the iPhone with `WCSession.transferCurrentComplicationUserInfo` and stored in the watch App Group container; the extension reads that file. Watch App Group: **TBD** on the free team (same caveat as phone widgets). Rendering mode: in tinted faces the `pulse` colour may be replaced by the system tint; use `widgetAccentable()` on the line and number only.

## Workout session (HealthKit)

- On Start: `HKWorkoutSession` with `HKWorkoutConfiguration(activityType: .traditionalStrengthTraining, locationType: .indoor)` and `HKLiveWorkoutBuilder` with `HKLiveWorkoutDataSource`. This keeps the app frontmost-capable, collects heart rate and active energy, and keeps the rest timer alive.
- Request HealthKit authorisation on the watch: share `HKObjectType.workoutType()`, read heart rate and active energy. Add `NSHealthShareUsageDescription` and `NSHealthUpdateUsageDescription` to `VitalisWatch/Info.plist`, and the `workout-processing` background mode.
- On End: `endCollection`, `finishWorkout`. The saved `HKWorkout` reaches the iPhone through Health sync and is exported by the existing `SyncEngine` as a `workout` sample. Store its UUID on the local session as `hkWorkoutUUID` (server field `hk_workout_uuid` in the documented workout shape).
- Sets are **not** HealthKit samples. They travel separately (below).
- Pause / resume map to `session.pause()` / `resume()`; rest does not pause the session.
- Crash recovery: `HKHealthStore.recoverActiveWorkoutSession` on launch; restore the in-memory session from the local queue.

## Local storage and offline queue (watch)

SwiftData store in the watch app container (or a JSON-lines file per session; either, but writes must be durable before the UI confirms a log).

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
- **Keep until acked**: `session(_:didFinish:error:)` on the watch only means delivered. The phone, after persisting, sends back `{"type": "ack", "setIDs": [...], "sessionID": ...}` via `transferUserInfo`. Only then may the watch mark records `ackedByPhone` and prune them (keep at least the last 14 days locally for freshness and prefill; **TBD** retention).
- Phone → watch: plan from the start-choice sheet (`{"type": "plan", ...}`), freshness snapshot for the Start suggestion, settings (rest, crown step), catalog updates, complication data.
- **Phone → server: TBD.** `POST /v2/workouts` is documented but not implemented on the server. Until it exists, the phone can send sets with the MCP `log_sets` tool (write token, set `id` makes retries safe, `session_id` keeps them together) or hold them locally. Decide which before wiring; held sets show in Settings → Sync as `WATCH SETS HELD` (03, frame `l4ps-S20fp`).

## Catalog

The Watch picker needs the exercise catalog offline. The server's catalog is free-exercise-db (public domain) plus custom exercises, with ids like `barbell-squat` and primary/secondary muscles. `GET /v2/exercises?since=` is documented but **not implemented**. **TBD**: either implement it, read it over MCP `find_exercises`, or bundle a snapshot (check free-exercise-db's licence terms before bundling). The iPhone owns the cache and sends it to the watch.

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
