# 11 · Scoring (server-side, v1 defaults)

Every number in this file is a **v1 default, tunable**. It was chosen for this package (design decision), not taken from a study. All constants live in one module, `app/src/scoring-config.ts`, so a later tune changes one file. Nothing here is left for the executor to decide.

The server computes every score, verdict, baseline, freshness value and trend (user decision, see [README](README.md#decided-principles)). The apps never re-derive them.

Pure functions live in new modules (no SQL inside them):

| Module | Contents |
|---|---|
| `app/src/scoring-config.ts` | Every constant below, exported as `const` objects |
| `app/src/scoring.ts` | Baselines, sleep score, recovery score, bands, verdict + copy |
| `app/src/training-analytics.ts` | Muscle load, heat, split readiness, session heat, weekly sets, e1RM trend |
| `app/src/fuel.ts` | Weight trend (EWMA), calorie and protein targets, adaptive target |
| `app/src/activity.ts` | Step/energy curves and ahead/behind pace |

The data they read and where results are cached is in [12-data-model.md](12-data-model.md). The JSON they appear in is in [10-server-api.md](10-server-api.md).

Unit tests for every function go in `app/tests/scoring.test.mjs` (and `training-analytics.test.mjs`, `fuel.test.mjs`) using the vectors in [§10](#10-test-vectors). Tests import from `../dist/src/…` after `npm run build`, like the existing tests (`app/tests/_env.mjs`).

Rounding: `round()` means round half away from zero to an integer unless a precision is given. `clamp(x)` means clamp to 0…100.

---

## 1. Days, nights and inputs

- A **day** is the owner's local day (existing rule, `app/src/time.ts`, `VITALIS_TZ`).
- A **night** belongs to the day the sleeper woke up (existing rule; `sleep_nights.day`, see `docs/native-sync.md` → Phase 1 clarifications).
- Per-day input values come from the existing `daily(key, from, to)` in `app/src/stats.ts`, which already picks one source per day (`pickPerDay`: Apple-merged source `''` first, then Watch, then others). Scores never read a value any other way, so the MCP tools and the app agree.
- Inputs per night, from the picked `sleep_nights` row: `asleep_h`, `sleep_start`, `sleep_end`, `in_bed_start`, `in_bed_end`, `awake_h`, and the new `wakeups` column ([12 §2.1](12-data-model.md#21-columns-added-to-existing-tables)).
- **HRV for a night** (`hrv_ms`): mean of live `HKQuantityTypeIdentifierHeartRateVariabilitySDNN` samples (`hk_values` view, metric `hrv`, picked source) whose start falls in `[sleep_start − 30 min, sleep_end + 30 min]`. If none (Health Auto Export history, or no Watch overnight), fall back to `daily("hrv", day, day)`. Store which was used as `hrv_basis: "overnight" | "daily"`.
- **Resting HR for a day** (`rhr_bpm`): `daily("resting_hr", day, day)`.
- Sleep stages (`core_h`, `deep_h`, `rem_h`) are **never** a scoring input (user decision: stages are the least accurate part). They are returned for display one tap down only.

## 2. Personal baselines

One baseline definition is used by scores, by "usual"/"typical range" in every endpoint, and by the MCP tools.

| Constant | v1 default | Notes |
|---|---|---|
| `BASELINE_DAYS` | **60** | Window = the 60 days before the day asked about; the day itself is excluded. Changes `app/src/stats.ts` `BASELINE_DAYS` from 30 to 60 (deliberate; update `mcp.test.mjs` expectations that assert `baseline_days: 30` and the "30 days" text in `INSTRUCTIONS` and tool descriptions in `app/src/mcp.ts`). |
| `MIN_BASELINE_DAYS` | 7 | Unchanged. Minimum days with a value before a **usual range** is shown. |
| `MIN_SCORE_DAYS` | **14** | Minimum days with a value before a baseline is used **inside a score** (HRV part, resting-HR part, bedtime consistency). |

For a metric with values `x₁…xₙ` in the window:

- **Centre** = median (`quantile(…, 0.5)`, the existing `stats.ts` helper).
- **Usual range** = 10th to 90th percentile (existing `stats.ts` behaviour, kept for display and flags).
- **Spread** (for z-scores) = `max(1.4826 × MAD, floor)`, where MAD is the median absolute deviation from the median. Floors: HRV `0.10` (in ln-units, about ±10 %), resting HR `2.0` bpm.
- HRV is scored in log space: centre and spread of `ln(hrv_ms)`. Displayed usual and range stay in ms.

**Before enough history** (fewer than `MIN_SCORE_DAYS` values): the part is `null` with `status: "calibrating"` and `nights_needed = 14 − n`. Endpoints show "Needs N more nights" ([20-ios-app.md](20-ios-app.md) → states). Fewer than 7 values: no usual range either (existing behaviour, `stats.ts` `baseline()` returns `usual: null` with a reason).

## 3. Sleep score (0–100)

Four parts, each 0–100 (user decision: duration vs need, bedtime consistency, efficiency, wake-ups).

### 3.1 Sleep need

`need_h` = `targets.sleep_need_h` if the owner set it. Otherwise, when there are ≥ 14 nights in the 60-night window: the **90th percentile** of `asleep_h`, rounded to the nearest 0.25 h, clamped to 7.0…9.0. Otherwise 8.0. (Design decision: the 90th percentile is what you sleep when you can, so a chronic short sleeper is not told their need is their deficit.)

### 3.2 Parts

| Part | Input | Formula (v1 default) | Missing when |
|---|---|---|---|
| **duration** | `r = asleep_h / need_h` | `clamp(round(100 × (r − 0.6) / 0.4))`. 100 at or above need, 0 at 60 % of need. No penalty for oversleeping in v1. | never (a night row always has `asleep_h`) |
| **consistency** | `d` = minutes between tonight's `eveningMinutes(sleep_start)` and the window's median bedtime (`app/src/time.ts` `eveningMinutes`, minutes past 18:00 so midnight wraps correctly) | `clamp(round(100 − |d| × 100 / 120))`. 0 at 2 h off. Earlier and later count the same. | fewer than 14 bedtimes in the window, or no `sleep_start` |
| **efficiency** | `bed_h` = `in_bed_end − in_bed_start` when both exist and `bed_h ≥ asleep_h`, else `sleep_end − sleep_start`. `e = min(1, asleep_h / bed_h)` | `clamp(round(100 × (e − 0.65) / 0.30))`. 100 at ≥ 95 %, 0 at ≤ 65 %. | neither interval available |
| **wakeups** | `n` = `wakeups` (count), `m` = `awake_h × 60` | `clamp(round(100 − 10 × max(0, n − 1) − 0.8 × m))`. The first wake-up is free. If `n` is null use only the `m` term; if `m` is null use only the `n` term. | both `n` and `m` null |

### 3.3 Total and band

- Weights: duration **0.40**, consistency **0.20**, efficiency **0.20**, wakeups **0.20**.
- Total = `round(Σ wᵢ·sᵢ / Σ wᵢ)` over the parts present (re-normalised). If duration is missing there is no score (`null`).
- Band: **good** ≥ 85, **ok** 70–84, **low** < 70. Labels: `GOOD`, `OK`, `LOW`.
- A part is **flagged** (tinted `watch` in the app) when its score is < 70.
- Each part returns a `detail` string the app shows verbatim (uppercase in UI): duration `OF YOUR 8H NEED`, consistency `18 MIN LATE` / `12 MIN EARLY` / `ON TIME` (|d| < 5), efficiency `94% ASLEEP`, wakeups `2 · 25 MIN` (or `25 MIN AWAKE` when `n` is null).

### 3.4 Worked example (computed with the reference implementation)

Night: asleep 7 h 41 m (7.683 h), need 8 h, bedtime 18 min later than the usual median, in bed 8 h 10 m (8.167 h), 2 wake-ups, 25 min awake.

| Part | Computation | Score |
|---|---|---|
| duration | r = 7.683 / 8 = 0.9604 → 100 × 0.3604 / 0.4 = 90.1 | **90** |
| consistency | 100 − 18 × 100/120 = 85 | **85** |
| efficiency | e = 7.683 / 8.167 = 0.9408 → 100 × 0.2908 / 0.30 = 96.9 | **97** |
| wakeups | 100 − 10 × 1 − 0.8 × 25 = 70 | **70** |
| total | 0.4×90 + 0.2×85 + 0.2×97 + 0.2×70 = 86.4 | **86 · GOOD** |

The approved frames show example numbers (85 etc.). They are illustrative; the formula was not bent to reproduce them.

## 4. Recovery score (0–100)

Parts (user decision): sleep score, HRV vs baseline, resting HR vs baseline.

| Part | Formula (v1 default) |
|---|---|
| **sleep** | the night's sleep score total (§3) |
| **hrv** | `z = (ln(hrv_ms) − centre_ln) / spread_ln`; score = `clamp(round(75 + 15 × z))`. Higher is better. |
| **resting_hr** | `z = (centre − rhr_bpm) / spread`; score = `clamp(round(75 + 15 × z))`. Lower resting HR is better, so the sign is flipped. |

- A typical night (z = 0) scores 75 on HRV and resting HR; one spread worse scores 60; two spreads worse 45.
- Weights: sleep **0.35**, hrv **0.40**, resting_hr **0.25**. Re-normalise over present parts.
- A score needs **at least two parts, including at least one of hrv / resting_hr**. Otherwise `score: null` with `status: "calibrating"` (baseline under 14 days) or `"missing"` (no HRV and no resting HR for the day, or no night).
- **Bands**: **ready** ≥ 75, **steady** 60–74, **ease** 45–59, **rest** < 45. Labels `READY`, `STEADY`, `EASE`, `REST`.
- **Guard**: if hrv z ≤ −1.5 **and** resting_hr z ≤ −1.5, the band is at most **ease** (both autonomic signals clearly off overrides a good sleep score).
- Display hints per part (returned by the server, used for arrows and tints, never recomputed by the app):
  - `arrow`: `up` if value > centre and |z| ≥ 0.25, `down` if value < centre and |z| ≥ 0.25, else `null`. (Arrow follows the raw value, so resting HR 57 vs 55 is `up`.)
  - `tint`: `good` if the better-direction z ≥ +0.5, `watch` if ≤ −0.5, else `null`. (Resting HR 57 vs 55 → z −1.0 → `watch`, as drawn in `spec/design/03-home-today.png`.)

### 4.1 Worked example

60-night history (28 nights present): HRV median 55 ms (ln spread floored at 0.10), resting HR median 55 bpm (spread floored at 2.0). Last night: sleep 86, HRV 62 ms, resting HR 57 bpm.

| Part | Computation | Score |
|---|---|---|
| sleep | from §3.4 | 86 |
| hrv | z = (ln 62 − ln 55) / 0.10 = 1.20 → 75 + 18 = 93 | 93 |
| resting_hr | z = (55 − 57) / 2.0 = −1.00 → 75 − 15 = 60 | 60 |
| total | (0.35×86 + 0.40×93 + 0.25×60) / 1.0 = 82.3 | **82 · READY** |

## 5. Verdict (headline + one action)

Computed by `scoring.ts` `verdict(input)` from: recovery band, whether the owner is trainable (§7.3), whether a strength session already exists today, fuel (§8), local time, and `bed_by` (§9.2). The result is a band label, a headline (≤ 2 lines of ≤ 18 characters each; the app sets it in condensed caps), a one-line reason, and **one** action.

Rules, first match wins:

| # | Condition | Headline | Action (`action.kind`, label) |
|---|---|---|---|
| 1 | Local time ≥ `bed_by − 90 min` | `Bed by HH:MM` | `bed_reminder`, `Remind me` |
| 2 | A strength session already logged today | `Done for today` (reason: session title + sets) | `log_meal` for the next slot if kcal left > 300 (`Log dinner`), else `bed_reminder` |
| 3 | Recovery `null` (missing or calibrating) and trainable | `Fresh to train` | `start_workout`, `Start workout` |
| 4 | Recovery `null`, not trainable | `No score yet` | `log_meal` next slot |
| 5 | band **ready** and trainable | `Train hard today` | `start_workout`, `Start workout` |
| 6 | band **steady** and trainable | `Train as planned` | `start_workout`, `Start workout` |
| 7 | band **ease** and trainable | `Go easy today` (reason adds "No records today") | `start_workout` with `intensity: "light"`, `Start light workout` |
| 8 | band **ready/steady/ease**, not trainable | `Muscles still loaded` | `log_meal` next slot |
| 9 | band **rest** | `Rest today` | `log_meal` next slot (if nothing left to eat: `bed_reminder`) |

- Headlines never name a split; the start sheet offers them (§7.3). The action label is `Start workout` and leaves Watch vs iPhone to the start sheet.
- The legacy MCP enum `get_brief.verdict.call` is kept for agents and derived from the band: ready → `good`, steady → `normal`, ease → `as_planned_no_records`, rest → `easy`, null → `unknown`. See [10 §8 MCP](10-server-api.md#8-mcp-tools).

### 5.1 Digest copy

`GET /v2/digest` headline = two lines:

| Sleep band | Line 1 | Recovery band | Line 2 (set in pulse red, approved exception) |
|---|---|---|---|
| good | `You slept well.` | ready | `Ready to push.` |
| ok | `You slept okay.` | steady | `Steady day.` |
| low | `Short night.` | ease | `Take it easy.` |
| null | `Morning.` | rest / null | `Rest today.` / `Let's see how today goes.` |

Plan rows (max 3, in this order, each only when it applies): the verdict's action (`Train legs` · `6 DAYS SINCE`), fuel (`Eat 2,300 kcal` · `155 G PROTEIN`), steps (`Walk 9,000` · `YOUR USUAL` when the target equals the rounded usual, else `YOUR TARGET`).

## 6. Activity: ahead / behind usual by now

Activity = steps and active energy against usual (user decision).

- **Curve per past day** (cached, [12 §3](12-data-model.md#3-how-computation-runs)): for steps and active energy, take the single source with the largest total that day from raw samples (`hk_values`, same tie rule as `pickPerDay`) and build 24 cumulative fractions `f[h]` = share of that source's daily total reached by the end of local hour `h`. Days with no raw samples (Health Auto Export history) have no curve.
- **Usual total** `U` = median of the merged daily totals (`daily("steps")`) over the 28 days before today; needs ≥ 7 days, else `null`.
- **Usual fraction now** `F(t)` = median over the curve days (≥ 7 needed) of `f` at the current local time, linearly interpolated within the hour.
- **Expected by now** `E = U × F(t)`.
- **Pace**: `early` if `E < 300` (steps) / `E < 30` (kcal); else `ahead` if today ≥ 1.10 E, `behind` if ≤ 0.90 E, else `on_pace`; `unknown` when `U` or `F` is null. Labels: `AHEAD`, `BEHIND`, `ON PACE`, nothing for `early`/`unknown`.
- Today's value is the merged daily total from the latest sync (`daily("steps", today, today)`).
- Exercise minutes: today's `daily("exercise_min")` against `targets.exercise_min` (default 30). No pace.

## 7. Training

### 7.1 Muscle load and heat (17 muscles)

Muscles = the 17 in `MUSCLES` (`app/src/exercises.ts`): abdominals, abductors, adductors, biceps, calves, chest, forearms, glutes, hamstrings, lats, lower back, middle back, neck, quadriceps, shoulders, traps, triceps. API slugs replace spaces with hyphens (`lower-back`, `middle-back`), matching `apple/briefs/assets/muscle-map-paths.json`.

- Working sets only (`kind != 'warmup'`, not deleted, session not deleted; existing rule in `training.ts`).
- Each working set adds weight **1.0** to each primary muscle and **0.5** to each secondary muscle of its exercise.
- **Load** at time `t`: `L = Σ wᵢ × exp(−Δhᵢ / 36)` over sets in the last 14 days, `Δh` = hours since the set. (τ = 36 h, half-life ≈ 25 h.)
- **Heat** 0–4: `0` = no working set touching the muscle in the last 30 days ("no data"); otherwise `1` fresh (L < 0.5), `2` recovering (0.5 ≤ L < 2), `3` partly loaded (2 ≤ L < 4), `4` loaded (L ≥ 4).
- **Days since** per muscle: whole local days since the last working set with the muscle as **primary** (existing `daysSinceTrained` rule, extended from the 11 `MAJOR_MUSCLES` to all 17); `null` = never.
- Labels for Today: `fresh_label` per §7.3 (`Push fresh`, `3 splits fresh`); `loaded_label` = the muscle group with the highest heat ≥ 3 + ` loaded` (`Chest loaded`), else `null`.

Worked example: 4 squat sets (quadriceps primary). Heat 4 right after, 3 at 12–24 h, 2 at 36–72 h, 1 (fresh) from 84 h. 8 sets: fresh from 108 h.

### 7.2 Splits

Nothing is predefined: the owner trains on no fixed calendar and changes order (25 Oct). Splits come from two places, in this order:

1. **Defined** in Settings (`splits` table, `PUT /v2/splits/:id`): a name and a set of muscles (slugs), in the owner's order. Exercises = the latest session whose `template` is the split id or whose title matches the name (case-insensitive), in set order; none yet → empty (pick as you go).
2. **History**: every other session title logged in the last `splitHistoryDays` (90) with at least one working set, by name, skipping generic titles (`Workout`, `Strength`, `Traditional Strength Training`) and names a defined split already has. Muscles = the primary muscles of the latest such session's working sets; exercises = its exercises.

Cardio needs no split: Apple's Workout app records it and it syncs as a Watch workout.

### 7.3 Ready splits

A split is **ready** when every one of its muscles has heat ≤ 1 (a split with no muscles is always ready). The list keeps the order above. Nothing is ranked or picked: the app offers the splits as equal choices and never names one. Each split's `days_since` = the minimum over its muscles (`null` when never trained, label `NEW`). `fresh_label` = `<Name> fresh` for one ready split, `<n> splits fresh` for more, `null` for none. **Trainable** (verdict input) = some split is ready; with no splits yet, no muscle is loaded (`loaded_label` is `null`).

### 7.4 Session heat (Watch summary, session detail)

Per muscle, weighted working sets in that one session (primary 1, secondary 0.5): ≥ 4 → 4, ≥ 2 → 3, > 0 → 2, 0 → 0.

### 7.5 Weekly sets per muscle

Monday-start local week. `sets[m]` = working sets with `m` primary (count 1) plus secondary (count 0.5), rounded to 0.5. Status against `targets.weekly_sets_min/max` (default 10/20): `under`, `in_range`, `over`. `muscles_hit` = muscles with `sets ≥ 1`, shown as `11/17`.

### 7.6 Estimated 1RM, records, suggestion

- **Epley** (existing `e1rm()` in `app/src/training.ts`): `w × (1 + reps/30)`, `w` when reps = 1, only for 1–12 reps, rounded to 0.1 kg, `null` otherwise. Always labelled an estimate.
- **PR**: a session's best e1RM for an exercise above every earlier best for it (existing `trainingSummary` logic). First time logged = `first_time: true`, not a PR tag.
- **e1RM trend**: one point per session (best working set) over the last 84 days. `change_8w` = last point − first point within the last 56 days (needs ≥ 2 points, else `null`).
- **Next time**: existing double-progression `suggest()` in `app/src/training.ts`, unchanged.

## 8. Fuel

### 8.1 Weight trend

Exponentially weighted moving average, α = **0.1** per weigh-in day: `T = T + 0.1 × (w − T)` on days with a weight; carried unchanged on days without. Seed: the trend value on the day before the requested window (computed from up to 120 days back), else the first weigh-in. One weight per day = `daily("weight_kg")` (picked source), which includes manual entries ([12 §2](12-data-model.md#2-schema-changes)). `month_change_kg` = trend today − trend 30 days ago (1 decimal).

### 8.2 Calorie target

`targets.kcal_mode` is `adaptive` (default) or `fixed`.

- **Initial / fixed default**: `round50(trend_kg × 30)` (2,300 for 76.4 kg), or 2,200 without any weight. Design decision: the exporter does not send age, sex or height (`apple/README.md` → Deliberately excluded types), so no BMR formula is possible.
- **Adaptive** (recomputed once per Monday-start week, lazily on the first read of the week, stored in `kcal_targets`):
  1. Window = the 21 days ending yesterday.
  2. Intake days = days with logged food ≥ 1,000 kcal. Need ≥ 14 intake days and ≥ 8 weigh-ins, else keep last week's target (`reason: "not_enough_data"`).
  3. Trend over the window (§8.1); `slope = (T_last − T_first) / 20` kg/day.
  4. `tdee = mean(intake) − slope × 7700` (7,700 kcal per kg, design default).
  5. Goal rate: `diff = goal_weight_kg − T_last`. |diff| ≤ 0.5 → 0; diff < 0 → `−min(0.005 × T_last, 0.75)` kg/week; diff > 0 → `+min(0.0025 × T_last, 0.35)` kg/week. No goal set → 0.
  6. `raw = tdee + rate × 7700 / 7`.
  7. New target = `round10(clamp(raw, prev − 150, prev + 150))`, floor 1,400.
- `kcal_left = target − eaten` (may be negative; the app shows `OVER BY 120`).
- Fuel counts **only Vitalis food entries** (`food_entries`). HealthKit `dietary*` samples (written by Vitalis or other apps) are stored raw by the exporter but never counted (prevents double counting; see [50-open-questions.md](50-open-questions.md#q5-count-food-logged-in-other-apps)).

Worked example (21-day fixture in §10.6): mean intake 2,276 kcal over 18 intake days, trend 76.890 → 76.337 kg, slope −0.0276 kg/day → tdee 2,488. Goal 74.0 → rate −0.382 kg/week → raw 2,069 → clamped to 2,300 − 150 = **2,150**. With goal 76.0 (within 0.5): raw 2,488 → **2,450**.

### 8.3 Protein target

`round5(trend_kg × 2.0)` g (155 g for 76.4 kg), or 140 g without weight, unless set. The frame `spec/design/23-setup-targets.png` shows 2.1 g/kg as example data.

### 8.4 Steps target

Default `round500(median of daily steps over the last 28 days)` (needs ≥ 7 days), else 8,000.

## 9. Sleep extras

### 9.1 Week

`GET /v2/sleep/week`: the 7 nights ending on the date, score per night, `avg_score` = mean of present scores (rounded), `bedtime_spread_min` = mean absolute deviation of the week's bedtimes (evening minutes) from their mean, rounded (`BED ± 24M`).

### 9.2 Tonight

`wake_time` = `targets.wake_time` if set, else the median `sleep_end` clock time of the last 14 nights rounded to 5 min (needs ≥ 7), else 07:00. `bed_by = wake_time − need_h`. Display: `Bed by 23:00 · 8H BEFORE YOUR 07:00 WAKE`.

## 10. Test vectors

All produced by running the reference implementation of these exact formulas (Node, 24 Oct 2026). Put them in the named test files as table-driven cases.

### 10.1 Sleep parts (`scoring.test.mjs`)

| Function | Input | Expected |
|---|---|---|
| duration | asleep 8, need 8 | 100 |
| duration | 7.5, 8 | 84 |
| duration | 6, 8 | 38 |
| duration | 4.8, 8 | 0 |
| duration | 9.5, 8 | 100 |
| duration | 7, 7.5 | 83 |
| consistency | d = 0 / 10 / 18 / 45 / 60 / 120 / 150 min | 100 / 92 / 85 / 63 / 50 / 0 / 0 |
| efficiency | asleep 7.6, bed 8 (0.950) | 100 |
| efficiency | 7, 8 (0.875) | 75 |
| efficiency | 6.5, 8 (0.813) | 54 |
| efficiency | 5, 8 (0.625) | 0 |
| efficiency | 8, 7.9 (capped at 1) | 100 |
| wakeups | n 0, m 0 | 100 |
| wakeups | 1, 5 | 96 |
| wakeups | 2, 25 | 70 |
| wakeups | 4, 40 | 38 |
| wakeups | null, 30 | 76 |
| wakeups | 3, null | 80 |
| wakeups | null, null | null |
| wakeups | 8, 90 | 0 |

### 10.2 Sleep total

| Parts {duration, consistency, efficiency, wakeups} | Total · band |
|---|---|
| 90, 85, 97, 70 | 86 · good |
| 90, null, 97, 70 | 87 · good |
| 90, null, null, null | 90 · good |
| null, 85, 97, 70 | null |
| 50, 40, 80, 60 | 56 · low |

### 10.3 Recovery parts

History fixture (28 nights): HRV cycles `[48, 52, 55, 58, 61, 55, 53]`, resting HR cycles `[54, 55, 56, 55, 54, 56, 55]`. Resulting baseline: HRV median 55 ms, usual range 48–61, ln spread 0.10 (floor); resting HR median 55, range 54–56, spread 2.0 (floor).

| Input | z | Score |
|---|---|---|
| HRV 62 | 1.20 | 93 |
| HRV 55 | 0 | 75 |
| HRV 45 | −2.01 | 45 |
| HRV 36 | −4.24 | 11 |
| HRV 80 | 3.75 | 100 |
| resting HR 57 | −1.00 | 60 |
| resting HR 55 | 0 | 75 |
| resting HR 52 | 1.50 | 98 |
| resting HR 60 | −2.50 | 38 |
| resting HR 73 | −9.00 | 0 |
| HRV 62 with only 13 history nights | — | null (calibrating, needs 1 more) |

### 10.4 Recovery total

| sleep, HRV, resting HR | Score · band |
|---|---|
| 86, 62, 57 | 82 · ready |
| 86, 55, 55 | 79 · ready |
| 60, 45, 60 | 49 · ease |
| 30, 36, 73 | 15 · rest |
| null, 62, 57 | 80 · ready |
| 86, null, 57 | 75 · ready |
| 86, null, null | null |
| 98, 47, 58 (HRV z −1.57, RHR z −1.5) | 68 → guard → ease |
| 100, 46, 58 | 67 → guard → ease |
| 95, 40, 61 | 52 · ease |

### 10.5 Freshness and e1RM (`training-analytics.test.mjs`)

| Sets (all at the same time) | Hours ago | L | Heat |
|---|---|---|---|
| 4 primary | 0 | 4.000 | 4 |
| 4 primary | 12 | 2.866 | 3 |
| 4 primary | 24 | 2.054 | 3 |
| 4 primary | 36 | 1.472 | 2 |
| 4 primary | 48 | 1.054 | 2 |
| 4 primary | 72 | 0.541 | 2 |
| 4 primary | 84 | 0.388 | 1 |
| 4 primary | 168 | 0.038 | 1 |
| 8 primary | 24 / 48 / 72 / 96 / 108 | 4.107 / 2.109 / 1.083 / 0.556 / 0.398 | 4 / 3 / 2 / 2 / 1 |
| 4 primary + 4 secondary at 26 h, plus 4 primary at 98 h | — | 3.177 | 3 |
| nothing in 30 days | — | 0 | 0 |

| e1RM input (kg × reps) | Expected |
|---|---|
| 100 × 6 | 120 |
| 82.5 × 6 | 99 |
| 100 × 1 | 100 |
| 60 × 12 | 84 |
| 60 × 13 | null |
| 0 × 5 | null |
| 100 × 0 | null |
| 20 × 10 | 26.7 |

### 10.6 Fuel (`fuel.test.mjs`)

Weights (21 days, null = no weigh-in): `76.8, null, 76.6, 76.9, null, 76.5, 76.4, 76.7, null, 76.3, 76.2, null, 76.4, 76.1, 76.0, null, 76.2, 75.9, null, 76.0, 75.8`, seed 76.9.
Trend: `76.89, 76.89, 76.861, 76.865, 76.865, 76.828, 76.786, 76.777, 76.777, 76.729, 76.676, 76.676, 76.649, 76.594, 76.534, 76.534, 76.501, 76.441, 76.441, 76.397, 76.337`.
Intakes: `2250, 2310, 2180, 2400, 900, 2290, 2350, 2200, 2260, null, 2300, 2280, 2190, 2330, 2240, 2270, 2210, 2350, 2300, null, 2250` (900 and nulls excluded → 18 intake days).

| Case | Expected |
|---|---|
| prev 2300, goal 74.0 | kcal 2150, tdee 2488, intake 2276, slope −0.0276, rate −0.382, raw 2069 |
| prev 2300, goal 76.0 | kcal 2450, rate 0, raw 2488 |
| only the first 10 intake values | kcal 2300 (kept), reason `not_enough_data` |
| initial target, trend 76.4 kg | kcal 2300, protein 155 g |

### 10.7 Pace (`activity.test.mjs`)

| Today, expected | Pace |
|---|---|
| 3206, 2600 | ahead |
| 3206, 3000 | on_pace |
| 2000, 3000 | behind |
| 150, 200 | early |
| 5000, null | unknown |

### 10.8 Stage independence

Changing a night's `core_h`, `deep_h`, `rem_h` (any values) leaves the sleep and recovery scores unchanged. Add this as a test.
