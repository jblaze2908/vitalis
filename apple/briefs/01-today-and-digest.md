# 01 · Today (Home) and morning digest

Implements:
- **V · Morning digest** `kh6EtZFCP9` → `spec/design/02-morning-digest.png`
- **V · Home (Today)** `PwXZkuGWcu` → `spec/design/03-home-today.png`
- **V · State · Today, sync stale** `Z6akLUWcKH` → `spec/design/24-state-today-sync-stale.png` (the Today side; the Sync side is in 03)

Uses from [spec/30-design-system.md](../../spec/30-design-system.md): StatusRow, PulseLine, ScreenHeader, ReadingRow, MonoLabel, MuscleMap, PrimaryButton, SecondaryButton, TabBar.

**Revised for the server-computes model.** Every number and word on these screens comes from `GET /v2/today` and `GET /v2/digest` ([spec/10 §4](../../spec/10-server-api.md#4-today-and-digest)); formulas are in [spec/11](../../spec/11-scoring.md). The app formats and lays out; it does not score, compare, or pick copy. Behaviour and states: [spec/20 §4, §6](../../spec/20-ios-app.md#today). This brief keeps the visual measurements.

## What the decision log fixes

- **Metric hierarchy** (24 Oct): hero = Recovery (sleep + HRV + resting HR, parts visible) · Activity as steps + active energy against usual · Calories left (protein second) · Training due with muscle freshness. **Weight is Body-tab only**, never on Today.
- **Home E order, fixed all day** (only content changes): 1 NOW verdict + one action, 2 Recovery with Sleep as a sub-score, 3 Fuel | Activity, 4 Training with the muscle map.
- **Morning digest** on the first open after waking.
- **Sleep score parts**: duration vs need, bedtime consistency, efficiency, wake-ups. Sleep stages are excluded.
- **Recovery parts**: sleep, HRV, resting HR.
- **The server computes everything** (24 Oct, owner decision for this package).
- From the research note: no black-box score (parts always visible, against your usual), every block ends in a next step, no streaks or guilt, sync freshness always visible.

## Screen: Home (Today) — `spec/design/03-home-today.png`

Top to bottom, 24 gutters. Field names are from the `GET /v2/today` body.

1. **StatusRow**: right label `SYNCED HH:MM` (steel) from `freshness.last_sync`. Offline/stale → see States.
2. **PulseLine** (phone): `pulse.window`, `pulse.now`, `pulse.events` (dips for wake, weigh-in, meals, workout; [spec/30 → PulseLine](../../spec/30-design-system.md#pulseline)).
3. **NOW block**: MonoLabel `NOW · <verdict.label>` in `pulse` (e.g. `NOW · READY`). Headline 46, two lines max: `verdict.headline` ("Train legs / hard today"), broken at the word boundary nearest the middle.
4. **Recovery block** (14 top): Number 92 `recovery.score` with MonoLabel `RECOVERY` 8 below; to its right, 20 gap, three ReadingRows: `SLEEP <parts.sleep.score>` (bone), `HRV <parts.hrv.value> <arrow>` (tint = `parts.hrv.tint`), `RESTING <parts.resting_hr.value> <arrow>` (tint = `parts.resting_hr.tint`), last row without rule. Arrows ↑/↓ from `arrow`. Tap Sleep row or the number → Sleep tab; HRV / Resting rows → Body tab, vitals section.
5. **Fuel | Activity** (16 top, rule above, 12 padding), two equal columns:
   - Left: MonoLabel `FUEL LEFT`, Number 32 `fuel.kcal_left` (negative → `OVER BY <abs>` in `watch`), MonoLabel bone `+ <fuel.next_label>` (tap → Quick add for `fuel.next_slot`).
   - Right: MonoLabel `STEPS`, Number 32 `activity.steps`, MonoLabel `OF <steps_target> · <PACE>` where PACE is `AHEAD` / `BEHIND` / `ON PACE` from `activity.steps_pace` (nothing for `early`/`unknown`). Second MonoLabel line: `<active_kcal> ACTIVE KCAL` + ` · <PACE>` from `active_kcal_pace` (decided: honours "Activity = steps and active energy" without changing the frame's layout).
6. **Training block** (14 top, rule above): MuscleMap both views at width 130 with `training.heat`, 14 gap, Headline 22 two lines: `training.fresh_label` bone ("Legs fresh"), `training.loaded_label` steel ("Chest loaded"; omitted when null).
7. **PrimaryButton** pinned 17 above the TabBar: `verdict.action.label`. Routing by `verdict.action.kind`: `start_workout` → start-choice sheet (03) or the remembered choice; `log_meal` → Quick add for `fuel.next_slot`; `bed_reminder` → schedule a notification 30 min before bed-by. Rule table: [spec/11 §5](../../spec/11-scoring.md#5-verdict-headline--one-action).
8. **TabBar**, TODAY active.

The screen does not scroll at 390×844 with default type. At larger Dynamic Type it scrolls; the PrimaryButton stays pinned.

## Screen: Morning digest — `spec/design/02-morning-digest.png`

Full-screen cover over Today, no TabBar. Body: `GET /v2/digest`.

1. StatusRow (`SYNCED HH:MM`), PulseLine from `pulse` (wake dip, now-dot near the start).
2. MonoLabel `<date_label> · <greeting>`; Headline 44 two lines: `headline[0]` bone, `headline[1]` `pulse` (the approved exception to rule 2).
3. **Sleep**: Number 96 `sleep.score` + MonoLabel `SLEEP`; ReadingRows (6 vertical padding) from `sleep.rows`: label, value, optional delta, tint per row.
4. **Recovery** (rule above): Number 48 `recovery.score`, MonoLabel `RECOVERY · <recovery.label>` in band tint (ready/steady `good`, ease and rest `watch`), reading line `HRV <v> <arrow> · RESTING <v> <arrow>` with tints from the response.
5. **YESTERDAY**: three columns: Number 24 `yesterday.steps` + `STEPS`, Number 24 `yesterday.active_kcal` + `ACTIVE KCAL` (decided: active energy, the Activity pillar), Headline 26 `yesterday.workout.title` or `Rest` with small label `NO WORKOUT`.
6. **TODAY** plan: `plan[]` (up to three rows), 50 tall, top rule each: 8 pt dot (`primary` row `pulse`, others `steel`), Headline 22 `title`, right MonoLabel `reason`.
7. **PrimaryButton** "Start my day", height 54, 38 from the bottom. Dismisses the digest.

### Trigger (decided)

- Server: `GET /v2/today` → `digest.available` is true when today's night exists and its `sleep_end` is at least 30 minutes ago; only the first night of the day counts (naps never re-trigger). [spec/10 §4](../../spec/10-server-api.md#get-v2digest--read).
- App: on `scenePhase == .active`, if `digest.available` and `UserDefaults digestDismissedDay != today.day` → fetch `/v2/digest` and present. "Start my day" sets `digestDismissedDay = day`.
- Reopen: tapping the date label on Today shows today's digest again; it never re-sets the dismissed flag.
- No night today → no digest; Today shows Recovery as missing.

## Data

| Block | Source field | Notes |
|---|---|---|
| Verdict | `verdict.{label, headline, reason, action}` | One action only |
| Recovery | `recovery.{score, band, status, reason, nights_needed, parts}` | `status` drives the no-score states |
| Fuel | `fuel.{kcal_left, kcal_target, protein_g, protein_target_g, next_slot, next_label}` | |
| Activity | `activity.{steps, steps_target, steps_pace, active_kcal, active_kcal_pace}` | No client-side pace |
| Training | `training.{heat, fresh_label, loaded_label, due, trained_today}` | 17 slugs in `heat` |
| PulseLine | `pulse.{window, now, events}` | Map time → x only |
| Freshness | `freshness.{last_sync, data_through}` | Stale rule in spec/20 §6 |

Models: `VitalisKit/APIModels/Today.swift`, `Digest.swift` (task I-03), decoded from the JSON in spec/10 with snake-case conversion. After each successful fetch, write `TodaySnapshot` for widgets and complications ([spec/20 §9](../../spec/20-ios-app.md#9-widgets-and-the-app-group)).

Refresh: on foreground, after the exporter's `syncNow()` completes, after any Outbox flush, every 15 min while foregrounded, and on pull to refresh (which also triggers `AppModel.syncNow()`). Requests send `If-None-Match`; a 304 keeps the cached body.

## States

| State | When | What shows |
|---|---|---|
| Loading | No cached body yet | Layout with labels; numbers `–` in `steel`; no shimmer (rule 3). PrimaryButton hidden. |
| Cached / offline | Refresh failed, cached body exists | Cached values; StatusRow `OFFLINE · UPDATED HH:MM` when older than 15 min. |
| Calibrating | `recovery.status = calibrating` | Recovery number `–` in steel, MonoLabel `NO RECOVERY SCORE`, body line `recovery.reason` ("Needs 9 more nights"). Other blocks render. |
| Night missing | `recovery.status = missing` | Same layout with `recovery.reason` ("No sleep recorded for last night"). |
| Stale sync | `freshness.last_sync` older than 12 h, or the exporter's last upload failed and its last success is older than 12 h | `24-state-today-sync-stale.png`: StatusRow `LAST SYNC <DAY>` in `watch`; a section with a 1.5 pt `watch` top rule, MonoLabel `NOT SYNCED SINCE <DAY>` in `watch`, Headline 36 cause, body "Everything is safe on this phone until it's fixed.", PrimaryButton **Fix sync** (the screen's one red action; the verdict action turns secondary). Cause copy per failure type: [spec/20 §6](../../spec/20-ios-app.md#6-offline-cache-and-stale-rules). |
| Empty training | `training.due` null and no sessions ever | MuscleMap all heat 0, "No workouts yet"; action "Start on Watch" as secondary. |
| Empty fuel | Nothing logged today | `FUEL LEFT` = full target (server value); label `+ LOG BREAKFAST` (server `next_label`). |

## Interactions

- Tap Recovery number or Sleep row → Sleep tab. HRV / Resting rows → Body tab, Vitals section.
- Tap `+ LOG <SLOT>` → Quick add sheet for that slot (03).
- Tap Steps → Body tab, Activity section.
- Tap MuscleMap / Training text → Train tab.
- PrimaryButton → per `verdict.action.kind` (above).
- Tap date label → reopen digest.
- Haptic: none on Today.

## Acceptance checklist

- [ ] Home matches `spec/design/03-home-today.png` at 390×844 with fixture data (overlay the PNG at 50 % in a preview; edges within 2 pt).
- [ ] Order never changes across morning / afternoon / evening fixtures; only content changes.
- [ ] Weight appears nowhere on Today.
- [ ] Exactly one red action on Home, the digest and the stale state (stale: Fix sync is red, the verdict action is secondary).
- [ ] HRV and resting HR arrows and tints come straight from the response (`arrow`, `tint`); resting 57 vs usual 55 fixture → ↑ in `watch`.
- [ ] No arithmetic in views or stores beyond formatting and PulseLine time → x (code review item).
- [ ] Digest matches `spec/design/02-morning-digest.png`; shows once per day when `digest.available`; "Start my day" dismisses; date tap reopens; relaunching the same day does not show it again.
- [ ] `digest.available = false` → no digest.
- [ ] Stale state matches `spec/design/24-state-today-sync-stale.png` with each cause's copy.
- [ ] VoiceOver reads "Now, ready. Train legs hard today", "Recovery 82", each reading row as one element.
- [ ] Previews: Home (normal, calibrating, missing night, stale 401, stale unreachable, empty training, empty fuel, loading, offline), digest (good night, short night, wake-ups flagged).
