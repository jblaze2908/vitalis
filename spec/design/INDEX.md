# Design index

Every approved frame exported from the Draft canvas **"Vitalis — Design v2"** (`3H9qPgAkyt`), rows y −19500 to −25300, plus the brand board and the locked identity reference. Exported 24 Oct 2026 from `https://draft.jaivardhansingh.com/i/<frame id>.png?scale=2`. All 35 files were checked with `file` (valid PNG) and are 36–350 KB.

- Phone frames: 780×1688 px = 390×844 pt @2x.
- Watch frames: the canvas frames are already @2x (416×496 px = 208×248 pt); the PNG export doubles that again (832×992 px). Halve every number in the frame HTML; measure from the HTML (`mcp__draft__get_frame`), not from pixels.
- **All numbers in the frames are example data.** Never ship them as defaults. Real values come from the endpoints named below.
- Only these frames are approved. Everything else on the canvas (J1–J7, Concepts, Options, Home A–E, Watch v1/v2, Identity A–C, tweaks 1–4) is history; do not build from it.
- Colours: use the LOCKED hexes in [30-design-system.md](../30-design-system.md). The brand board (00) shows older hexes (#0B0D10, #FF4D3D, #F2EFEA, #868B94, #23272D); they are superseded.

| File | Frame id | What it shows | Spec / endpoint |
|---|---|---|---|
| `00-brand-board.png` | `fDbT_3oo7i` | Vital line brand system: wordmark, app icon, type, colour (older hexes), five rules | [30](../30-design-system.md) |
| `01-locked-identity-reference.png` | `ICfJcWLNVV` | LOCKED identity reference (final mix: pure black, #FF5233, condensed caps + expanded light numbers) | [30](../30-design-system.md) |
| `02-morning-digest.png` | `kh6EtZFCP9` | Morning digest: greeting + two-line headline, Sleep score with 4 rows, Recovery, yesterday, today's plan, Start my day | [20 §4](../20-ios-app.md#morning-digest) · `GET /v2/digest` |
| `03-home-today.png` | `PwXZkuGWcu` | Today: NOW verdict, Recovery + Sleep/HRV/Resting, Fuel left, Steps vs usual, muscle map + labels, Start legs on Watch | [20 §4](../20-ios-app.md#today) · `GET /v2/today` |
| `04-sleep-tab.png` | `3WxLux5k-j` | Sleep: score + duration/vs usual/need, four part bars, week of scores, Tonight bed-by + Remind me | `GET /v2/sleep`, `GET /v2/sleep/week` |
| `05-body-tab.png` | `SRN5GTWmV2` | Body: weight trend + raw dots + source, activity (steps, active kcal, exercise min) + week bars, vitals vs typical range | `GET /v2/body` |
| `06-train-tab.png` | `d68BO9oR4S` | Train: freshness muscle map + legend, Legs are due + Start, week stats, sessions list | `GET /v2/training` |
| `07-eat-tab.png` | `BwU_mhJYzc` | Eat: kcal left + macros, Usual/Search/Scan/Describe, meals, Add usual button, adaptive target note | `GET /v2/food/day` |
| `08-log-weight-sheet.png` | `fW4EJo7EKL` | Log weight half sheet: value, ruler, when, also save to Apple Health, Save | `POST /v2/weight` + HealthKit write (20 §8) |
| `09-session-detail-push.png` | `u9QwaxL_dQ` | Session detail: session heat map, sets/volume/avg bpm, exercise rows with PR tag | `GET /v2/training/sessions/:id` |
| `10-exercise-detail-bench-press.png` | `SimAaL4Zws` | Exercise detail: estimated 1RM + 8-week change, e1RM chart, heaviest, next time, last sets | `GET /v2/exercises/:id` |
| `11-workout-start-choice.png` | `3qVL-kZTgZ` | Start choice sheet: Start on Watch / Log on iPhone, remember my choice | `GET /v2/training` (`due`) · [21 §6](../21-watch-app.md#6-transfer-to-iphone-and-the-server) |
| `12-workout-logging-iphone.png` | `7v36M3Kqfq` | iPhone logging: rest block, set table (last/kg/reps/check), other exercises, add exercise, Finish | `GET /v2/exercises/:id`, `POST /v2/workouts` |
| `13-quick-add-food.png` | `8kBom9fyeU` | Quick add sheet: Search/Scan/Describe tiles, usual at lunch, recent, saved meals | `GET /v2/food/quick` |
| `14-food-search.png` | `eI_8DOJ_cz` | Food search: segmented control, field, results (estimate / Open Food Facts), describe link | `GET /v2/food/search` |
| `15-describe-and-confirm.png` | `LJ3iovmSnT` | Describe & confirm: typed meal, parsed items with portion steppers, totals, Add | `POST /v2/food/describe`, `POST /v2/food/entries` |
| `16-barcode-scan.png` | `SRVfnL_In1` | Barcode scan found: viewfinder, product panel, Add to snacks | `GET /v2/food/barcode/:code` |
| `17-scan-not-found.png` | `sBdU_XEO7O` | Scan not found: photograph label / describe / type numbers | `PUT /v2/food/barcode/:code` |
| `18-eat-just-added.png` | `3T4bhbTv67` | Eat after adding: JUST NOW meal + Undo toast | `POST /v2/food/entries`, `DELETE /v2/food/meals/:meal_id` |
| `19-setup-welcome.png` | `iU0mdElwnO` | Welcome: muscle map, wordmark, three features, Get started | [20 §4 Setup](../20-ios-app.md#setup-first-run) |
| `20-setup-connect-server.png` | `gi1tdbhnmF` | Connect server: URL + write token, CONNECTED · TOKEN CAN WRITE | `GET /v2/sync/status` (`token.can_write`) |
| `21-setup-health-access.png` | `_YkjyAR57M` | Health access: areas read + write, Allow in Health | HealthKit authorisation (20 §8) |
| `22-setup-reading-history.png` | `ufOqf8gNFu` | Reading your history: percent, month being read, samples sent, time left | local `SyncEngine.snapshot()` |
| `23-setup-targets.png` | `uNuXYF1h84` | Targets: steps, calories (adaptive), protein, sleep need, goal weight, Finish | `GET /v2/targets` (`suggested`), `PUT /v2/targets` |
| `24-state-today-sync-stale.png` | `Z6akLUWcKH` | Today with stale sync: LAST SYNC WED, cause, Fix sync | `freshness.last_sync` · [20 §6](../20-ios-app.md#6-offline-cache-and-stale-rules) |
| `25-state-sync-token-rejected.png` | `l4ps-S20fp` | Sync paused: token rejected, nothing is lost, Replace token / Try again, waiting counts | local exporter + Outbox (20 §5.3) |
| `26-state-train-empty.png` | `4t-ld-gF6e` | Train with no workouts yet | `GET /v2/training` (`empty: true`) |
| `27-state-eat-empty.png` | `fk2O2KyeR-` | Eat with nothing logged: full target, Start with breakfast | `GET /v2/food/day` (`empty: true`) |
| `28-settings.png` | `ZlARNorqzI` | Settings: server, targets, training, version | `GET/PUT /v2/targets`, `GET /v2/sync/status` |
| `29-widgets-home-lock.png` | `lDPxhnSr9k` | Widgets: small, medium, lock-screen circular and rectangular | `TodaySnapshot` (20 §9) |
| `30-watch-start.png` | `kNA_vRK_cy` | Watch Start: FRESH · 6 DAYS, Legs, Start, repeat rows | `WatchPack` · [21 §2.1](../21-watch-app.md#21-start-frame-30) |
| `31-watch-set-entry.png` | `pCSw4PpAhl` | Watch set entry: weight, reps, last, set dips, Log set | [21 §2.2](../21-watch-app.md#22-set-entry-frame-31) |
| `32-watch-rest.png` | `AIJAljEgAy` | Watch rest: countdown, next set, ±15, edge progress | [21 §2.3](../21-watch-app.md#23-rest-frame-32) |
| `33-watch-summary.png` | `k_nhjKQwwv` | Watch summary: SAVED, session heat map, title, min/sets/PR | `POST /v2/workouts` response (`session.heat`, `prs`) · [21 §2.8](../21-watch-app.md#28-summary-frame-33) |
| `34-watch-face-complications.png` | `9KeK3X1BI1` | Watch face content spec for complications | `TodaySnapshot` · [21 §3](../21-watch-app.md#3-complications-frame-34) |

## Screens without an approved frame

Specified in words; build them with the tokens and rules in [30](../30-design-system.md) and flag them for design review in the PR description.

| Screen | Where specified |
|---|---|
| Watch live metrics (swipe) | [21 §2.4](../21-watch-app.md#24-live-metrics-no-frame--specify-in-words) |
| Watch next-exercise handoff | [21 §2.5](../21-watch-app.md#25-next-exercise-handoff-no-frame) |
| Watch add exercise | [21 §2.6](../21-watch-app.md#26-add-exercise-no-frame) |
| Watch end workout | [21 §2.7](../21-watch-app.md#27-end-workout-no-frame) |
| iPhone add-exercise search sheet, set-field input state, date/time picker in Log weight, Replace token sheet, Settings edit sheets | [apple/briefs/03-tabs-and-flows.md](../../apple/briefs/03-tabs-and-flows.md) (system sheet patterns in Vital line tokens) |
