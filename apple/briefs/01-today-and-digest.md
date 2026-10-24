# 01 · Today (Home) and morning digest

Implements:
- **V · Morning digest** `kh6EtZFCP9`
- **V · Home (Today)** `PwXZkuGWcu`
- **V · State · Today, sync stale** `Z6akLUWcKH` (the Today side; the Sync side is in 03)

Uses from 00: StatusRow, PulseLine, ScreenHeader, ReadingRow, MonoLabel, MuscleMap, PrimaryButton, SecondaryButton, TabBar.

## What the decision log fixes

- **Metric hierarchy** (24 Oct): hero = Recovery (sleep + HRV + resting HR, parts visible) · Activity as steps + active energy against usual · Calories left (protein second) · Training due with muscle freshness. **Weight is Body-tab only**, never on Today.
- **Home E order, fixed all day** (only content changes): 1 NOW verdict + one action, 2 Recovery with Sleep as a sub-score, 3 Fuel | Activity, 4 Training with the muscle map.
- **Morning digest** on the first open after waking.
- **Sleep score parts**: duration vs need, bedtime consistency, efficiency, wake-ups. Sleep stages are excluded.
- **Recovery parts**: sleep, HRV, resting HR.
- From the research note: no black-box score (parts always visible, against your usual), every block ends in a next step, no streaks or guilt, sync freshness always visible.

## Screen: Home (Today) — `PwXZkuGWcu`

Top to bottom, 24 gutters:

1. **StatusRow**: right label `SYNCED HH:MM` (steel). Stale → see States.
2. **PulseLine** (phone).
3. **NOW block**: MonoLabel `NOW · <RECOVERY BAND>` in `pulse` (e.g. `NOW · READY`). Headline 46, two lines max: the verdict ("Train legs / hard today"). 
4. **Recovery block** (14 top): Number 92 (`78`) with MonoLabel `RECOVERY` 8 below; to its right, 20 gap, three ReadingRows: `SLEEP 85` (bone), `HRV 62 ↑` (tint by better/worse vs usual), `RESTING 57 ↑` (tint), last row without rule. Tapping the block opens the Sleep tab for the Sleep row, Body → Vitals for HRV / resting rows (TBD: confirm targets).
5. **Fuel | Activity** (16 top, rule above, 12 padding), two equal columns:
   - Left: MonoLabel `FUEL LEFT`, Number 32 (`1,780`), MonoLabel bone `+ LOG <NEXT MEAL>` (tap → quick add, 03).
   - Right: MonoLabel `STEPS`, Number 32 (`3,206`), MonoLabel `OF 9,000 · AHEAD` (`AHEAD` / `BEHIND` vs usual pace).
   - **TBD**: the hierarchy says Activity = steps **and** active energy, but the frame shows steps only. Decide whether active kcal gets a line here (e.g. second MonoLabel) or stays on Body.
6. **Training block** (14 top, rule above): MuscleMap both views at width 130, 14 gap, Headline 22 two lines: first line bone ("Legs fresh"), second steel ("Chest loaded").
7. **PrimaryButton** pinned 17 above the TabBar: the one action of the verdict ("Start legs on Watch"). Its target follows the verdict: start workout (03 start-choice sheet, or straight to Watch if remembered), log a meal, or wind down. **TBD**: action list per verdict.
8. **TabBar**, TODAY active.

The screen does not scroll at 390×844 with default type. At larger Dynamic Type it scrolls; the PrimaryButton stays pinned.

## Screen: Morning digest — `kh6EtZFCP9`

Full-screen cover over Today, no TabBar.

1. StatusRow (`SYNCED 07:04`), PulseLine with the wake dip and now-dot near the start.
2. MonoLabel `SAT 24 OCT · GOOD MORNING`; Headline 44 two lines: line 1 bone ("You slept well."), line 2 `pulse` ("Ready to push.") — the approved exception to rule 2.
3. **Sleep**: Number 96 (`85`) + MonoLabel `SLEEP`; ReadingRows (6 vertical padding): `DURATION 7H41 +12M` (delta tinted), `BEDTIME 23:02`, `EFFICIENCY 94%`, `WAKE-UPS 2` (tinted `watch` when worse than usual).
4. **Recovery** (rule above): Number 48 (`78`), MonoLabel `RECOVERY · READY` in band tint, reading line `HRV 62 ↑ · RESTING 57 ↑` with tinted arrows.
5. **YESTERDAY**: three columns — Number 24 steps, Number 24 kcal, Headline 26 workout name or `Rest` with small label `NO WORKOUT`. **TBD**: "KCAL" here is total or active energy (2,240 in the example reads like total).
6. **TODAY** plan: up to three rows, 50 tall, top rule each: 8 pt dot (first row `pulse`, others `steel`), Headline 22 action, right MonoLabel reason. Example rows: Train legs / 6 DAYS SINCE · Eat 2,300 kcal / 160 G PROTEIN · Walk 9,000 / YOUR USUAL.
7. **PrimaryButton** "Start my day", height 54, 38 from the bottom. Dismisses the digest.

### Trigger (define exactly)

Show the digest when **all** hold:
- The app comes to the foreground (`scenePhase == .active`).
- HealthKit has a `sleepAnalysis` asleep sample whose `endDate` falls on **today's local date** and the night it belongs to has ended (no asleep sample for a settle window; **TBD** the window, proposal 30 min). The night belongs to the day you woke up, same rule as the server.
- `digestDismissedDay != today` (local, persisted in `UserDefaults`).

"Start my day" sets `digestDismissedDay = today`. If no sleep sample for today exists, there is no digest; Today shows the no-score state.

Reopen: tapping the date label on Today (`SAT 24 OCT`) shows today's digest again; it never re-sets the dismissed flag.

**TBD**: whether naps (a second asleep block later the same day) can re-trigger; proposal: no, first night block only.

## Data model

Put models in `VitalisKit` (shared with the Watch and widgets). All `Sendable`, `Codable`.

```swift
struct Baseline: Codable, Sendable {           // per metric
    var median: Double?
    var low: Double?                           // usual range low
    var high: Double?                          // usual range high
    var nights: Int                            // history used
}

struct SleepScore: Codable, Sendable {
    var total: Int?                            // 0–100, nil when not computable
    var duration: Part                         // asleep vs need
    var bedtimeConsistency: Part               // bedtime vs usual bedtime
    var efficiency: Part                       // asleep / in bed
    var wakeUps: Part                          // count + minutes awake
    var asleep: TimeInterval; var need: TimeInterval
    var bedtime: Date; var wake: Date
    struct Part: Codable, Sendable { var score: Int?; var detail: String; var flag: Flag? }
}

struct RecoveryScore: Codable, Sendable {
    var total: Int?                            // 0–100
    var band: Band                             // .ready / … (copy drives "READY")
    var sleep: Int?                            // = SleepScore.total
    var hrv: Reading                           // last night vs HRV baseline
    var restingHR: Reading                     // vs resting-HR baseline
}

struct Reading: Codable, Sendable { var value: Double?; var baseline: Baseline; var flag: Flag? } // flag: .better/.worse/nil
struct ActivityToday: Codable, Sendable { var steps: Int; var stepsTarget: Int; var activeKcal: Double; var pace: Pace }
struct FuelToday: Codable, Sendable { var kcalTarget: Int; var kcalEaten: Int; var proteinTarget: Int; var proteinEaten: Int }
struct MuscleFreshness: Codable, Sendable { var daysSince: [Muscle: Int?]; var heat: [Muscle: Int]; var due: WorkoutSuggestion? }
struct TodaySnapshot: Codable, Sendable {      // also written to the App Group for widgets (03)
    var day: String; var recovery: RecoveryScore?; var sleep: SleepScore?
    var activity: ActivityToday?; var fuel: FuelToday?; var training: MuscleFreshness?
    var verdict: Verdict?; var lastSync: Date?; var computedAt: Date
}
```

### Score rules: what is locked, what is TBD

| Item | Status |
|---|---|
| Recovery parts = sleep score, HRV, resting HR | Locked |
| HRV and resting HR compared against a **60-night personal baseline** | Specified in the task brief for this work |
| Server "usual" = median of the 30 days before the day, range = 10th–90th percentile, `null` under 7 days (`docs/api.md`) | Exists on the server |
| Sleep need "from your last 60 nights" | Shown on the Targets frame `uNuXYF1h84` |
| **TBD** | Align the baselines: 60 nights on device vs the server's 30 days. Pick one window or show which is used. |
| **TBD** | Recovery formula: weights of the three parts and how each part maps to 0–100. |
| **TBD** | Sleep formula: how duration vs need, bedtime deviation, efficiency and wake-ups each map to 0–100 (frame examples: 7h41 of 8h → 90, 18 min late → 85, 94 % → 94, 2 wake-ups / 25 min → 70, total 85), and their weights. |
| **TBD** | Bands and copy: score ranges for READY and the other bands, and their colours. |
| **TBD** | Minimum history before a score shows (server uses 7 days for `usual`). |
| **TBD** | Verdict rule: how recovery band + training due + fuel produce the headline and the one action. The server's `get_brief.verdict.call` enum (`easy · as_planned_no_records · normal · good · unknown`) can seed it. |
| **TBD** | Steps pace (`AHEAD`/`BEHIND`): against target pro-rata or against usual-by-this-hour. |
| Wake-ups and efficiency use sleep/wake only; stages (core/deep/REM) are never inputs | Locked |

Build the scoring as a pure function (`ScoreEngine.score(nights:hrv:restingHR:need:)`) with unit tests, so the formula can change without touching views.

## Data sources

| Data | Source | Notes |
|---|---|---|
| Sleep night (in bed, asleep, awake segments) | HealthKit `sleepAnalysis` on device | Sleep/wake only. Group into nights by wake day. |
| HRV | HealthKit `heartRateVariabilitySDNN` | Overnight value; **TBD** which sample (last overnight, overnight mean). |
| Resting HR | HealthKit `restingHeartRate` | Daily value for today. |
| Steps, active energy | HealthKit statistics (`HKStatisticsQuery`, cumulative, source-merged) | Same merge Apple uses, as the exporter's `daily_stats`. |
| Calories eaten, protein | Local meal store (03 Eat), mirrored to HealthKit | Not on the server. |
| Targets (steps, kcal, protein, sleep need) | Local settings (03 Setup → Targets) | |
| Training freshness | Local set store (02, 03) | Days since each muscle's last working set (warm-ups excluded, primary muscles only — server rule in `daysSinceTrained`). |
| Last sync | `SyncHistory.lastSuccess` from `SyncEngine.snapshot()` | Drives `SYNCED HH:MM` and the stale state. |
| Server-computed brief | `get_brief` over MCP only | **TBD** whether the app should ever read the server for Today. No HTTP read route exists. |

**Default for v1: compute Today on device from HealthKit and local stores.** The server receives the same raw samples through the existing exporter, so nothing is lost. This is a build decision, flagged for the owner to confirm: the stale-state frame's copy ("Last night's sleep and heart data haven't reached Vitalis yet") assumes the score comes from the server. If v1 computes on device, a sync outage does not remove the score; the no-score state happens only when HealthKit lacks the night. **TBD**: confirm on-device scoring, then adjust that copy.

Refresh Today on foreground, on HealthKit observer callbacks the app already registers, and after any local log (meal, set). Cache the last `TodaySnapshot` so the screen opens instantly.

## States

| State | When | What shows |
|---|---|---|
| Loading | First compute after launch, no cached snapshot | Layout with labels; numbers as `–` in `steel`; no skeleton shimmer (rule 3). PrimaryButton hidden. |
| Cached | Cached snapshot older than this foreground | Show cached values immediately, refresh in place. No spinner. |
| No score yet | No sleep night for today, or under the minimum history (TBD) | Recovery number `–` in steel, MonoLabel `NO RECOVERY SCORE`, one body line saying why ("No sleep recorded for last night" / "Needs N more nights"). Fuel, Activity, Training still show. |
| Stale sync | `now − lastSuccess` above the stale threshold (**TBD**: no value in the log or frames) | Frame `Z6akLUWcKH`: StatusRow `LAST SYNC <DAY>` in `watch`; a section with a 1.5 pt `watch` top rule, MonoLabel `NOT SYNCED SINCE <DAY>` in `watch`, Headline 36 cause, body "Everything is safe on this phone until it's fixed.", PrimaryButton **Fix sync** (it becomes the screen's one red action, so the training block's Start turns secondary). |
| Stale: token rejected | Last sync error is `HTTPAPIClient.Failure.http(401)` | Headline "Your server stopped accepting uploads." Fix sync → Settings → Sync (03). |
| Stale: other cause | Network, 5xx, protected data unavailable | **TBD**: copy for each cause (frame covers 401 only). |
| Empty training | No sets ever logged | Training block shows the MuscleMap all heat 0 and "No workouts yet"; action "Start on Watch" as secondary. |
| Empty fuel | Nothing logged today | `FUEL LEFT` shows the full target; label `+ LOG BREAKFAST`. |
| HealthKit denied | No readable sleep/heart types | No-score state with "Allow Health access" SecondaryButton → Settings app. HealthKit hides read denials, so detect by "no samples ever", not by auth status. |

## Interactions

- Tap Recovery number or Sleep row → Sleep tab. HRV / Resting rows → Body tab, Vitals section.
- Tap `+ LOG LUNCH` → quick add sheet for that meal (03).
- Tap Steps → Body tab, Activity section.
- Tap MuscleMap / Training text → Train tab.
- PrimaryButton → per verdict (above).
- Tap date label → reopen digest.
- Pull to refresh: re-runs the score and triggers `AppModel.syncNow()`.
- Haptic: none on Today.

## Acceptance checklist

- [ ] Home matches `PwXZkuGWcu` at 390×844 with fixture data (overlay the frame PNG at 50 % in a preview; edges within 2 pt).
- [ ] Order never changes across morning / afternoon / evening fixtures; only content changes.
- [ ] Weight appears nowhere on Today.
- [ ] Exactly one red action on Home, the digest and the stale state (stale: Fix sync is red, Start is secondary).
- [ ] HRV and resting HR tints follow better/worse (resting 57 above usual → `watch`), arrows shown.
- [ ] Digest matches `kh6EtZFCP9`; shows once per day after the night ends; "Start my day" dismisses; date tap reopens; killing and relaunching the app the same day does not show it again.
- [ ] No sleep sample for today → no digest, Today shows the no-score state.
- [ ] Stale state matches `Z6akLUWcKH` when `lastSuccess` is older than the threshold and the last error is 401.
- [ ] `ScoreEngine` is a pure function with unit tests for each part and for missing inputs (returns `nil`, never 0).
- [ ] Scores never use sleep stages (test: changing stage labels does not change the score).
- [ ] VoiceOver reads "Now, ready. Train legs hard today", "Recovery 78", each reading row as one element.
- [ ] Previews: Home (normal, no score, stale 401, empty training, empty fuel, loading), digest (good night, short night, wake-ups flagged).
