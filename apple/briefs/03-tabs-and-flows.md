# 03 · Tabs, flows, setup, sync, settings, widgets

Everything on the iPhone except Today (01). Uses every component in 00. Each section names its frames; each screen has its own acceptance list at the end of the section.

Shared screen frame for tabs: StatusRow → PulseLine → ScreenHeader (MonoLabel context + Headline 46) → sections separated by rules → TabBar. Sheets: 00 → Spacing (top 104 or 486-tall half sheet).

---

## Sleep tab — `3WxLux5k-j`

- Header context `LAST NIGHT · 23:02 TO 06:51`, title `Sleep`, trailing day back / forward 36×36 SecondaryButtons (forward disabled on today).
- Hero: Number 88 score + MonoLabel `SCORE · GOOD`; ReadingRows `DURATION 7H41`, `VS USUAL +12M` (tinted), `NEED 8H00`.
- **WHAT MADE IT 85**: four part rows, 42 tall, grid `1fr | 96 | 34`: name (reading) + detail (MonoLabel 10: `OF YOUR 8H NEED`, `18 MIN LATE`, `94% ASLEEP`, `2 · 25 MIN`), ProgressTrack (fill = part score %, `watch` when flagged), part score (Number 20, tinted when flagged). Parts and formulas: 01 → Score rules (TBD formulas).
- **THIS WEEK**: WeekBars of nightly scores with score labels above, header right `AVG 81 · BED +/- 24M` (bedtime spread). **TBD**: bar height scale (frame: 81 → 40 pt, 88 → 48 pt).
- **TONIGHT**: MonoLabel, Headline 26 `Bed by 23:00`, MonoLabel 10 `8H BEFORE YOUR 07:00 ALARM`, SecondaryButton `Remind me` (schedules a local notification; ask notification permission on first tap).
  - **TBD**: wake/alarm time source. HealthKit does not expose the Sleep Focus schedule or alarms; proposal: a wake-time setting, defaulting to the median wake time of recent nights.
- **No red action** on this screen (agent judgement in the decision log).
- Stages are not shown here (they sit "one tap down"; **TBD** whether a stages detail exists at all in v1).
- Data: HealthKit `sleepAnalysis`, score engine from 01.

Acceptance: matches `3WxLux5k-j`; back/forward changes night and all sections; flagged part tints bar and value `watch`; Remind me schedules a notification for bed-by minus a lead time (**TBD** lead); no red button; preview for a night with no data (`–` and "No sleep recorded").

## Body tab — `SRN5GTWmV2`

- Header context date, title `Body`, trailing SecondaryButton `+ Log weight` (opens Log weight sheet).
- **WEIGHT · KG TREND**: Number 60 trend value; ReadingRows `THIS MONTH -0.6` (tint: toward goal = `good`), `GOAL 74.0`. Chart 342×56: raw readings as `rawDot` circles r 2.2, trend as a 2 pt `bone` curve, end dot r 3.5, 1 pt `rule` baseline; caption MonoLabels `76.6 TODAY · SCALE 07:02` (latest raw reading, **source name** and time) and `30 DAYS`.
  - **Sources**: HealthKit `bodyMass` from any source (smart scales, Health app, Vitalis). Show the source of the latest reading from `sourceRevision.source.name`. Manual entries from Vitalis are written to HealthKit and show `VITALIS`.
  - **Trend first** (research note: recent-weighted trend, raw readings faint). **TBD**: trend algorithm and parameters (e.g. exponentially weighted average; no parameters are set anywhere).
- **ACTIVITY · TODAY**: three columns — steps (`OF 9,000 STEPS`), active kcal (`ACTIVE KCAL`), exercise minutes (`OF 30 MIN`); WeekBars of steps. **TBD**: source of the 30-minute exercise target (Apple's exercise goal is not readable in all OS versions; proposal: a local setting).
- **VITALS · VS YOUR TYPICAL RANGE**: rows 36 tall, grid `1fr | 92 | 78`: HRV, RESTING HR, SpO2, BREATHING. RangeBar shows the usual range band and today's dot; value Number 19 with unit MonoLabel 10. Out of range → tint by better/worse; neutral metrics (breathing) get no tint (server semantics).
  - Typical range = server's definition (10th–90th percentile of the 30 days before today, none under 7 days), computed on device. **TBD**: if 01 moves baselines to 60 nights, use the same window here.
- No red action.

### Log weight sheet — `fW4EJo7EKL`

- Half sheet 486 tall. Row: `CANCEL` (MonoLabel bone) | Headline 22 `Log weight` | empty.
- Number 84 value + MonoLabel `KG`; MonoLabel 10 `LAST 76.8 YESTERDAY · TREND 76.4`.
- Ruler picker, 60 tall: ticks every 0.1 kg (1 pt × 14 `future`), major every 0.5 kg (26 tall `tickMajor`), centre indicator 2×44 `bone`, labels under majors. Drag or Crown-like scroll with a light haptic per 0.1 kg. Prefilled with the last reading.
- ReadingRows (52 tall): `WHEN TODAY · 07:05` (tap → date/time picker), `ALSO SAVE TO APPLE HEALTH` toggle (on by default; bone track, black knob).
- PrimaryButton `Save 76.6 kg`, 38 from the bottom.
- Save: store locally; if the toggle is on, write `HKQuantitySample(bodyMass)` with `HKMetadataKeyWasUserEntered = true`. The exporter then sends it to the server. If off, the reading stays local-only (**TBD**: should a local-only reading reach the server another way? Today there is no route).
- Units: kg only in v1 (**TBD** lb).

Acceptance: matches `SRN5GTWmV2` and `fW4EJo7EKL`; a scale reading in Health shows with its source name; saving with the toggle on creates a Health sample with Vitalis as source and the trend updates; toggle off creates no Health sample; vitals tints match better/worse; no red action on the tab.

## Train tab — `d68BO9oR4S`

- Header context `THIS WEEK · 18 TO 24 OCT`, title `Train`.
- MuscleMap both views at 220, centred; legend MonoLabels 10 with 8 pt squares: FRESH (bone), RECOVERING (steel), LOADED (pulse).
- Due block: Headline 28 `Legs are due` + MonoLabel `6 DAYS · 5 EXERCISES`; PrimaryButton `Start legs on Watch` → start-choice sheet (or straight to the remembered choice).
- Week stats, three columns: `SESSIONS`, `WORKING SETS`, `MUSCLES HIT` (`11/17`, the 17 = muscle count in 00).
- **SESSIONS** list, rows 52: date column (MonoLabel day + Number 20 date), Headline 21 title + MonoLabel 10 `58 MIN · 19 SETS`, right MonoLabel tag (`PR · BENCH` in `good`, `CARDIO`). Strength sessions from the local set store; cardio rows from HealthKit workouts (`HKWorkout`, non-strength activity types) with average heart rate.
- Data: local set store (Watch + iPhone logs). **TBD**: history from before the app existed (server has sessions logged via MCP; no HTTP read route; `list_workouts` over MCP is the only path).

### Workout start: Watch or iPhone — `3qVL-kZTgZ`

- Half sheet 486 tall over a dimmed Train.
- MonoLabel `FRESH · 6 DAYS SINCE`, Headline 56 `Legs`, exercise list as reading text (`SQUAT · ROMANIAN DEADLIFT · …`).
- PrimaryButton with watch glyph `Start on Watch`, caption MonoLabel 10 `LOG SETS FROM YOUR WRIST · PHONE STAYS AWAY`.
- SecondaryButton with phone glyph `Log on iPhone`, caption `FULL SET TABLE · GOOD FOR NEW EXERCISES`.
- Checkbox row (18×18, radius 4, `future` ring) `REMEMBER MY CHOICE`. When set, the Train/Today buttons skip the sheet; change it in Settings → Training (**TBD**: the Settings frame has no row for it; add one).
- Start on Watch: send the plan over WatchConnectivity (02), then `HKHealthStore().startWatchApp(with: HKWorkoutConfiguration)` (strength, indoor). If the Watch is not paired / not installed, show an inline error under the button and offer Log on iPhone.

### Workout logging on iPhone — `7v36M3Kqfq`

- Full screen, no TabBar. StatusRow label `WORKOUT · LIVE`. Header context `22:41 · 5 OF 16 SETS` (elapsed, sets done of planned), title workout name, trailing SecondaryButton `Finish`.
- **Rest block**: MonoLabel `REST · NEXT 100 x 6`, Number 52 countdown, mini buttons `-15S` `SKIP` `+15S`, ProgressTrack (remaining fraction). Hidden when no rest is running.
- **Current exercise**: Headline 26 name + MonoLabel 10 `BEST 100 x 6`. Table header MonoLabels 10: `SET | LAST | KG | REPS | ✓`, grid `30 | 1fr | 66 | 56 | 38`, rows 46:
  - Done rows: number steel (`W` for warm-up), LAST reading steel, fields with `rule` ring and steel text, check in a `future`-ringed square.
  - Current row: set number `pulse`, LAST `bone`, focused field `pulse` ring, check button **filled `pulse`** with a black tick (the screen's one red action, decision log).
  - Upcoming rows: everything `disabled`, empty check square with `rule` ring.
  - Fields: Number 17, wdth 125 wght 300. Tap opens a decimal keypad (**TBD**: keypad vs ± steppers; no frame for the input state). Prefill like the Watch (02).
  - `+ ADD SET` (MonoLabel bone, centred).
- Other exercises collapsed below, rows 48: Headline 20 steel + MonoLabel 10 `3 SETS · LAST 95 x 8`. Tap to make current.
- SecondaryButton `+ Add exercise` pinned 34 from the bottom → catalog search sheet (same catalog as 02; **TBD** source).
- Check tap: logs the set (same `LoggedSet` model as 02), starts rest (default from Settings), haptic `.success`.
- Finish: confirm, save the session, show the session detail.
- **TBD**: whether iPhone logging also runs an `HKWorkoutSession` on iPhone (iOS 17+ supports it) to record an `HKWorkout` like the Watch does.
- If a Watch workout is live, the iPhone shows the same session read-only, updating as sets arrive (**TBD**: confirm; avoids double logging).

### Session detail — `u9QwaxL_dQ`

Back link MonoLabel `TRAIN`; context `THU 22 OCT · 18:42 · 58 MIN`; title; MuscleMap 230 with session-load heat (rule in 02); stats `SETS`, `KG VOLUME` (working sets only), `AVG BPM` (from the overlapping `HKWorkout`); exercise rows 52 with `4 SETS · TOP 82.5 x 6`, `PR` tag in `good`, chevron → exercise detail. No red action.

### Exercise detail — `SimAaL4Zws`

Back link to the session; context `BARBELL · CHEST, TRICEPS, SHOULDERS` (equipment + primary muscles); title; Number 72 estimated 1RM + MonoLabel `KG · EST. 1-REP MAX` + reading `+3.1 KG IN 8 WEEKS` in `good`. Chart 342×120: 3 `rule` gridlines, `bone` 2 pt polyline of per-session best e1RM, hollow steel points r 3, last point filled r 4.5, date MonoLabels. `HEAVIEST 82.5 x 6` | `NEXT TIME, TRY 82.5 x 7`. Last session's sets as chips (34 tall, radius 8, `rule` ring; top set `future` ring, bone text).
- e1RM: Epley `w × (1 + reps/30)`, only for 1–12 reps (server rule).
- "Next time, try": the server's double-progression rule (`get_exercise_history.next`, `app/src/training.ts`). **TBD**: port the rule to the app (read `training.ts` first) or fetch it over MCP.

Acceptance (Train): all five frames match; sheet remembers the choice; Start on Watch launches the watch app in the simulator pair; iPhone table logs, rests and finishes; the current row's check is the only red element; session and exercise detail numbers recompute from fixture sets (volume excludes warm-ups; e1RM only 1–12 reps).

## Eat tab and food flows

Frames: Eat `BwU_mhJYzc`, Quick add `8kBom9fyeU`, Food search `eI_8DOJ_cz`, Describe & confirm `LJ3iovmSnT`, Barcode scan `SRVfnL_In1`, Scan not found `sBdU_XEO7O`, Just added `3T4bhbTv67`, Empty `fk2O2KyeR-`.

**Storage.** The server has no food code. Meals live in a local SwiftData store (meal → items with kcal, protein, carbs, fat, portion, source). Each logged item is also written to HealthKit as an `HKCorrelation(.food)` with `dietaryEnergyConsumed`, `dietaryProtein`, `dietaryCarbohydrates`, `dietaryFatTotal` samples and `HKMetadataKeyFoodType`; keep the HealthKit UUIDs on the local row. The exporter then sends them to the server unchanged. Usual, recent and saved meals are local only.

### Eat tab — `BwU_mhJYzc`

- Header context `TODAY · SAT 24 OCT`, title `Eat`, day back/forward.
- Number 64 kcal left + MonoLabels `KCAL LEFT`, `520 OF 2,300`; ProgressTrack eaten/target; macros in three columns (`PROTEIN 38 / 160 G` etc., each with a ProgressTrack).
- Quick actions, four columns: USUAL, SEARCH, SCAN, DESCRIBE (56×52 secondary squares with icons, MonoLabel 10 below).
- Meal sections: Headline 22 meal + MonoLabel time, Number 20 meal total; items as ReadingRows (`MASALA OMELETTE · 3 EGGS 310`).
- Next meal section (by time of day) shows `+ ADD` and a PrimaryButton with the usual for that meal: `Add usual: chicken rice bowl` + `640` (the screen's one red action). One tap logs it.
- Footer MonoLabel 10 `TARGET 2,300 KCAL ADJUSTS WEEKLY FROM YOUR WEIGHT TREND`. **TBD**: the adaptive target algorithm (no rule exists anywhere); until defined, the target is the fixed value from Setup.
- **TBD**: meal slots (breakfast, lunch, snacks, dinner?) and their time windows.
- "Usual" = the most frequent meal logged in that slot. **TBD**: how many repeats make a usual ("after a few days" in `fk2O2KyeR-`).

### Quick add sheet — `8kBom9fyeU`

Sheet from top 104. Title `Add to lunch` with a slot picker chevron. Three mode tiles (80 tall, `future` ring): SEARCH, SCAN, DESCRIBE. `YOUR USUAL AT LUNCH`: Headline 26 meal + MonoLabel macros + 52×52 `pulse` plus button. `RECENT` and `SAVED MEALS` rows (54 tall): reading name + MonoLabel portion/when, Number 18 kcal, 34×34 secondary plus. Any plus logs immediately and shows the Undo toast.

### Search — `eI_8DOJ_cz`

Segmented control SEARCH / SCAN / DESCRIBE (MonoLabels, active bone with a 2 pt bone underline over the middle 40 %). Search field 48 tall, `future` ring, reading 14 text. `5 RESULTS`, rows 58: name, MonoLabel `1 PLATE, 200 G · ESTIMATE` or `100 G · OPEN FOOD FACTS`, kcal, plus. Footer link "Not quite it? Describe the meal".
- **Open Food Facts** (docs checked 24 Oct 2026): product by barcode `GET https://world.openfoodfacts.org/api/v3.6/product/{barcode}.json`; v3 has **no text search** (legacy `/cgi/search.pl` or the separate Search-a-licious API). Limits: 15 product reads and 10 searches per minute per IP. Send a custom `User-Agent: Vitalis/<version> (<contact>)` (**TBD** contact address). **TBD**: which text-search API to use.
- **TBD**: source of the `ESTIMATE` rows (generic dishes such as "Paneer tikka"): there is no dataset or service for them yet.
- Debounce typing; show local matches (recent/saved) first.

### Describe & confirm — `LJ3iovmSnT`

Text box (reading 14, `future` ring) with the user's words. `WE FOUND 3 ITEMS` / `TAP TO ADJUST`. Item rows: Headline 21 name, Number 20 kcal, stepper (28×28 squares, `−` / `+`, portion in reading) and macros `P 7 · C 44 · F 4`. Caption `ESTIMATED FROM YOUR WORDS · CHECK PORTIONS BEFORE ADDING`. Pinned macro totals + PrimaryButton `Add to lunch · 665 kcal`.
- **Parsing is TBD.** It needs an LLM. **Never put an LLM API key in the app** (secrets stay on the server, as with the write token). Proposal: a server route on the user's Vitalis host that the app calls with the write token. No such route exists; do not invent one in code. Build the screen against a `MealParser` protocol with a fixture implementation.
- Research note: photo/AI logging underestimates; keep the "check portions" caption.

### Barcode scan — `SRVfnL_In1` · Scan not found — `sBdU_XEO7O`

- Full screen, `camera` backdrop, StatusRow `SCANNING`, close button (40×40 secondary, ✕), MonoLabel `ADDING TO SNACKS`. Viewfinder 280×180 with 30 pt corner brackets (3 pt `bone`). Use `DataScannerViewController` (VisionKit, EAN/UPC symbologies) or AVFoundation metadata output. Add `NSCameraUsageDescription`.
- Found: MonoLabel `FOUND · <digits>`; bottom panel (sheet colours): MonoLabel `200 ML BOTTLE · OPEN FOOD FACTS`, Headline 30 product, Number 40 kcal, macro row, PrimaryButton `Add to snacks`.
- Not found: viewfinder ring 2 pt `watch`; panel MonoLabel `NOT FOUND · <digits>` in `watch`, Headline 30 `Not in Open Food Facts yet`, body copy as in the frame, three option rows (62 tall, chevrons): **Photograph the label** (on-device text recognition with Vision; **TBD** parsing rules for nutrition labels), **Describe it** (→ Describe), **Type the numbers** (manual per-serving form). Whatever the user picks is saved against the barcode locally ("we'll remember this barcode").

### Just added + Undo — `3T4bhbTv67`

After any add: the meal shows MonoLabel `JUST NOW` (bone) and its items; a toast 56 tall, 16 side insets, bottom 99 (above the TabBar), `toast` background, 1 pt `track` ring, radius 12: tick, reading `ADDED TO LUNCH · 665 KCAL`, divider, Action 19 `Undo`. Haptic `.success` on show. Undo deletes the local rows and the HealthKit samples (the exporter sends the deletions). Auto-dismiss: **TBD** duration (no value in the designs).

### Empty Eat — `fk2O2KyeR-`

StatusRow `NOTHING LOGGED`; Number 96 full target `2,300` + MonoLabel `KCAL TO GO · 160 G PROTEIN`; Headline 30 `Start with breakfast` (slot by time); body "Meals you repeat become one tap after a few days."; three 84-tall tiles SEARCH / SCAN / DESCRIBE.

Acceptance (Eat): all eight frames match; one tap on a usual logs it and writes HealthKit samples; Undo removes both; barcode found and not-found paths work with fixtures and one real OFF lookup (custom User-Agent sent); Describe runs against the fixture parser only; at most one red element per screen.

---

## Setup / onboarding

Frames: Welcome `iU0mdElwnO`, Connect server `gi1tdbhnmF`, Health access `_YkjyAR57M`, Reading your history `ufOqf8gNFu`, Targets `uNuXYF1h84`. Full screen, no TabBar, StatusRow label `SETUP` / `STEP n OF 4`; PulseLine progress variant where the now-dot marks the current step. PrimaryButton 44 from the bottom.

1. **Welcome**: MuscleMap 290 (example heat), wordmark 210×55, Headline 30 two lines (`Sleep, recovery, training and food.` bone / `On a server you own.` steel), three numbered feature rows, `Get started`.
2. **Connect server**: Headline 44 `Connect your server`, body copy. Fields: `SERVER` (URL, reading 14) and `WRITE TOKEN` (secure, dots, `Paste` chip). Helper `vitalis token create iphone --scope write`. On Continue: `ServerSettings(url)` validation, `TokenStore.save`, then `GET /v2/sync/status` (existing `HTTPAPIClient.status()`); 200 → MonoLabel `CONNECTED · TOKEN CAN WRITE` in `good`. Errors inline in `watch`: invalid URL, unreachable, 401.
   - **TBD**: `/v2/sync/status` accepts any token scope, so a 200 does not prove the token can write. Either add a scope field to the status response (server change) or change the copy to `CONNECTED`.
   - The token is never shown again after saving (Keychain, `AfterFirstUnlockThisDeviceOnly`, existing code). Never log it.
3. **Health access**: list of areas (SLEEP, HEART, ACTIVITY, WORKOUTS, BODY, NUTRITION READ + WRITE); note that reads need the phone unlocked; `Allow in Health` → `requestAuthorization(toShare:read:)`.
   - **Code change**: `AppModel.authorize()` currently passes `toShare: []`. Add share types: `bodyMass`, `dietaryEnergyConsumed`, `dietaryProtein`, `dietaryCarbohydrates`, `dietaryFatTotal` (and `workoutType` if iPhone logging records workouts). Add `NSHealthUpdateUsageDescription` to `Vitalis/Info.plist`. Update `apple/README.md`, which says no write access is requested.
4. **Reading your history**: Number 96 percent, `NOW READING MARCH 2023`, PulseLine from first sample to today, ReadingRows `SAMPLES SENT 1.84M`, `TIME LEFT ABOUT 9 MIN`, `SERVER CONNECTED`. Secondary `Set targets while this runs`. Progress comes from `SyncEngine.snapshot()`; backfill keeps running (existing `requestHistoryBackfill`).
   - **TBD**: how to compute percent and time left (HealthKit gives no total count; proposal: date of the current page between the oldest sample date and today).
5. **Targets**: rows 68 tall: Headline 22 name + MonoLabel basis, Number 30 value: Steps (`YOUR USUAL IS 8,600`), Calories (`ADJUSTS WEEKLY FROM WEIGHT`), Protein (`2.1 G PER KG`), Sleep need (`FROM YOUR LAST 60 NIGHTS`), Goal weight (`NOW 76.4 KG`). Tap a row to edit. `Finish` → Today.
   - **TBD**: starting-value rules: steps (median of history?), calories (no formula), protein g/kg default, sleep need from 60 nights (which statistic), goal weight (no default; user input).

Acceptance (Setup): five frames match; Continue blocked until the status call succeeds; 401 and unreachable show inline errors; Health sheet requests the new share types; backfill survives leaving the app; Finish lands on Today and never shows setup again unless the token is cleared.

## Sync states and Settings

### Settings — `ZlARNorqzI`

Title `Settings`. Groups (MonoLabel heading, ReadingRows 10 vertical padding): **SERVER** (`SERVER host`, `WRITE TOKEN IN KEYCHAIN`, `SYNC 2 MIN AGO` in `good` → Sync screen), **TARGETS** (steps, calories `ADAPTIVE · 2,300`, protein, sleep need), **TRAINING** (`WEEKLY SETS PER MUSCLE 10–20`, `DEFAULT REST 2:00`, `CROWN WEIGHT STEP 2.5 KG`), footer `VITALIS 0.1 · PERSONAL BUILD`. Add: remembered workout start choice, Acknowledgements (fonts OFL, muscle map MIT), Reset local export state (existing), Replace token. Rows open an edit sheet. **TBD**: where `WEEKLY SETS PER MUSCLE` is used (no screen shows it yet).

### Sync screen and token rejected — `l4ps-S20fp`

Back link `SETTINGS`, title `Sync`. Healthy: last sync, pending batches, per-type status, last 20 batches (restyled existing `SyncView` content). Token rejected (`HTTPAPIClient.Failure.http(401)` on the last attempt):
- StatusRow label `SYNC PAUSED` in `watch`; section with a 1.5 pt `watch` top rule; MonoLabel `TOKEN REJECTED · SINCE WED 4:12 PM`; Headline 36 `Nothing is lost.`; body with counts of waiting batches, samples and workouts; PrimaryButton `Replace token` + SecondaryButton `Try again` side by side.
- ReadingRows: `SERVER REACHABLE` (good), `WRITE TOKEN REJECTED (401)` (watch), `WAITING TO UPLOAD 3 BATCHES`, `WATCH SETS HELD 16`.
- Data is kept on the phone: anchors do not advance without a 200 (existing engine behaviour); Watch sets stay in the local store (02).
- Replace token → secure field sheet → `TokenStore.save` → retry `syncNow()`.
- **TBD**: whether "since" needs a new field (the engine records `lastError`, not the time of the first failure).

The stale banner on Today is in 01.

Acceptance (Sync/Settings): both frames match; forcing a 401 shows the rejected state with real pending counts; Replace token + Try again resumes and clears the state; no token value ever appears on screen or in logs.

## Widgets — `lDPxhnSr9k`

New widget extension target `VitalisWidgets` (iOS). Families:
- **systemSmall** (158×158, padding 14): PulseLine widget variant 130×18, Number 54 recovery, MonoLabel `READY` in band tint, Headline 19 verdict.
- **systemMedium** (158 tall, 14/16 padding): MonoLabel `TODAY · 09:39` + `+ LOG MEAL` (bone, deep link), ReadingRows `STEPS 3,206 / 9,000`, `FUEL LEFT 1,780 KCAL`, `PROTEIN 38 / 160 G`.
- **accessoryCircular**: Number 24 recovery + MonoLabel `READY`.
- **accessoryRectangular**: Headline 18 `Legs today` + reading 11 steps and kcal left.
Background `sheet`, radius 22 (system widget shape), 1 pt `rule` inset ring.

Data path: the app writes `TodaySnapshot` (01) as JSON into the App Group container after every recompute and calls `WidgetCenter.shared.reloadAllTimelines()`. The widget only reads that file; it never queries HealthKit or the network. Deep links: `vitalis://today`, `vitalis://eat/add` (proposed scheme; register `CFBundleURLTypes`).

**App Groups are required** (`group.$(BUNDLE_PREFIX).vitalis`) for the app, the widget extension and the watch complication extension. **TBD**: test App Group provisioning on the free team first; the frame itself says so. If unavailable, ship without widgets.

Acceptance (Widgets): small, medium and both lock-screen families match `lDPxhnSr9k` with a fixture snapshot; widgets update within one timeline reload after logging a meal; a missing snapshot shows `–` values, not example numbers.
