# Vitalis SwiftUI build briefs

Per-screen build specs for the Vitalis iPhone + Apple Watch app in the locked **Vital line** identity: exact sizes, type roles, spacing, interactions and acceptance checklists, measured from the approved frames.

**Revised 24 Oct 2026 for the server-computes model.** The owner decided that the server computes every score, verdict, baseline, freshness value, trend and target; the apps display server results, cache them, and send raw data. The canonical package is **[`spec/`](../../spec/README.md)**:

- Data, endpoints and JSON: [spec/10-server-api.md](../../spec/10-server-api.md)
- Formulas (v1 defaults): [spec/11-scoring.md](../../spec/11-scoring.md)
- App architecture, networking, cache, outbox, states, HealthKit write-back: [spec/20-ios-app.md](../../spec/20-ios-app.md)
- Watch flows, offline store, WatchConnectivity: [spec/21-watch-app.md](../../spec/21-watch-app.md)
- Design system: [spec/30-design-system.md](../../spec/30-design-system.md)
- Executor tasks and build order: [spec/40-tasks.md](../../spec/40-tasks.md)
- Approved frame PNGs: [spec/design/INDEX.md](../../spec/design/INDEX.md)

Precedence: decision log > `spec/` > these briefs. The former TBDs in these briefs are resolved in `spec/` and linked where they were. The earlier default of scoring on the phone from HealthKit is withdrawn.

## Files

| File | Covers |
|---|---|
| [00-design-system.md](00-design-system.md) | Pointer: the design system moved to spec/30 |
| [01-today-and-digest.md](01-today-and-digest.md) | Home (Today), morning digest, stale state: layout + which response fields fill it |
| [02-watch-logger.md](02-watch-logger.md) | watchOS logger screens, rest timer, summary, complications (visuals; behaviour in spec/21) |
| [03-tabs-and-flows.md](03-tabs-and-flows.md) | Sleep, Body, Train (incl. iPhone set table), Eat (quick add, search, describe, scan), setup, sync states, Settings, widgets |
| [assets/muscle-map-paths.json](assets/muscle-map-paths.json) | SVG path data for the muscle map (MIT, see spec/30 → MuscleMap) |

## Build order

Follow [spec/40-tasks.md](../../spec/40-tasks.md): server tasks S-00…S-19, then iPhone I-01…I-12, then Watch and widgets W-01…W-03. The iPhone design-system task (I-01) can start as soon as S-00 has created the integration branch; screens need the endpoint shapes (from spec/10 fixtures) but not a running server.

## How to use a brief

- Read [spec/30](../../spec/30-design-system.md) first. Every screen uses its tokens and components. Never hard-code a hex value, font name or size in a screen.
- Implement against the PNGs in `spec/design/`; for exact measurements read the frame HTML (`mcp__draft__get_frame`). Phone frames are 1x at 390×844 pt; Watch frames are @2x at 416×496 px = 208×248 pt, so halve every Watch number in the HTML.
- All numbers in the frames are **example data**. Never ship them as defaults; real values come from the endpoints.
- Each brief ends with an acceptance checklist. Tick every line against a running build (simulator is fine unless the line says device) and a SwiftUI preview.
- After any change: build both schemes, run `VitalisTests`. Commands are in `apple/README.md`.

## Project facts the briefs rely on

From `apple/README.md` and `apple/project.yml` on `feat/apple-exporter`:

- XcodeGen project `Vitalis`. Targets: `Vitalis` (iOS app), `VitalisWatch` (watchOS app, embedded), `VitalisTests`. Local package `VitalisKit`.
- Swift 6, `SWIFT_STRICT_CONCURRENCY: complete`, `SWIFT_DEFAULT_ACTOR_ISOLATION: nonisolated`. So every view model and observable store needs an explicit `@MainActor`.
- iOS 18.0, watchOS 11.0. No third-party dependencies. Keep it that way.
- Bundle ids `$(BUNDLE_PREFIX).vitalis` and `$(BUNDLE_PREFIX).vitalis.watchkitapp`, signing from the ignored `Config/Signing.xcconfig`.
- The iPhone app already exports every readable HealthKit sample to `POST /v2/samples` (`SyncEngine` actor, anchors, idempotent batches) and reads `GET /v2/sync/status`. The write token lives in Keychain (`TokenStore`, service `Vitalis.API`).
- **Not yet compiled.** The exporter was written on Linux. The first Mac build may need fixes (task I-01).
- The Watch app is a placeholder screen ("Workouts coming soon").

## Server contract

On `main` today (`app/src/server.ts`): `GET /health`, `POST /ingest`, `POST /v2/samples`, `GET /v2/sync/status`, `/mcp`. Everything the screens read or write is specified as new routes in [spec/10](../../spec/10-server-api.md) (today, digest, sleep, body, weight, training, exercises, workouts, food, targets) and built in tasks S-01…S-19. Until those land, build screens against the JSON fixtures in spec/10.

## Approved frames

| Frame | Id | PNG | Brief |
|---|---|---|---|
| V · Morning digest | `kh6EtZFCP9` | `02-morning-digest.png` | 01 |
| V · Home (Today) | `PwXZkuGWcu` | `03-home-today.png` | 01 |
| V · State · Today, sync stale | `Z6akLUWcKH` | `24-state-today-sync-stale.png` | 01, 03 |
| V · Watch start @2x | `kNA_vRK_cy` | `30-watch-start.png` | 02 |
| V · Watch set entry @2x | `pCSw4PpAhl` | `31-watch-set-entry.png` | 02 |
| V · Watch rest @2x | `AIJAljEgAy` | `32-watch-rest.png` | 02 |
| V · Watch summary @2x | `k_nhjKQwwv` | `33-watch-summary.png` | 02 |
| V · Watch face @2x | `9KeK3X1BI1` | `34-watch-face-complications.png` | 02 |
| V · Sleep tab | `3WxLux5k-j` | `04-sleep-tab.png` | 03 |
| V · Body tab | `SRN5GTWmV2` | `05-body-tab.png` | 03 |
| V · Train tab | `d68BO9oR4S` | `06-train-tab.png` | 03 |
| V · Eat tab | `BwU_mhJYzc` | `07-eat-tab.png` | 03 |
| V · Workout start: Watch or iPhone | `3qVL-kZTgZ` | `11-workout-start-choice.png` | 03 |
| V · Workout logging on iPhone | `7v36M3Kqfq` | `12-workout-logging-iphone.png` | 03 |
| V · Log weight sheet | `fW4EJo7EKL` | `08-log-weight-sheet.png` | 03 |
| V · Quick add food | `8kBom9fyeU` | `13-quick-add-food.png` | 03 |
| V · Session detail: Push | `u9QwaxL_dQ` | `09-session-detail-push.png` | 03 |
| V · Exercise detail: Bench press | `SimAaL4Zws` | `10-exercise-detail-bench-press.png` | 03 |
| V · Food search | `eI_8DOJ_cz` | `14-food-search.png` | 03 |
| V · Describe & confirm | `LJ3iovmSnT` | `15-describe-and-confirm.png` | 03 |
| V · Barcode scan | `SRVfnL_In1` | `16-barcode-scan.png` | 03 |
| V · Scan not found | `sBdU_XEO7O` | `17-scan-not-found.png` | 03 |
| V · Eat tab, just added | `3T4bhbTv67` | `18-eat-just-added.png` | 03 |
| V · Setup · Welcome | `iU0mdElwnO` | `19-setup-welcome.png` | 03 |
| V · Setup · Connect server (1 of 4) | `gi1tdbhnmF` | `20-setup-connect-server.png` | 03 |
| V · Setup · Health access (2 of 4) | `_YkjyAR57M` | `21-setup-health-access.png` | 03 |
| V · Setup · Reading your history (3 of 4) | `ufOqf8gNFu` | `22-setup-reading-history.png` | 03 |
| V · Setup · Targets (4 of 4) | `uNuXYF1h84` | `23-setup-targets.png` | 03 |
| V · State · Sync, token rejected | `l4ps-S20fp` | `25-state-sync-token-rejected.png` | 03 |
| V · State · Train, no workouts yet | `4t-ld-gF6e` | `26-state-train-empty.png` | 03 |
| V · State · Eat, nothing logged yet | `fk2O2KyeR-` | `27-state-eat-empty.png` | 03 |
| V · Settings | `ZlARNorqzI` | `28-settings.png` | 03 |
| V · Widgets · Home & Lock Screen | `lDPxhnSr9k` | `29-widgets-home-lock.png` | 03 |
| Vitalis identity · Brand system (Vital line) | `fDbT_3oo7i` | `00-brand-board.png` | spec/30 |
| Vital line · LOCKED identity reference | `ICfJcWLNVV` | `01-locked-identity-reference.png` | spec/30 |

Draft canvas: **"Vitalis — Design v2"**, id `3H9qPgAkyt`. Only the frames above are approved; everything else on the canvas is history.

## Decision log

The plan of record is the Obsidian note `Context Intelligence/_Inbox/vitalis-native-app-design.md`. Market research: `vitalis-fitness-app-market-research.md`. Free-team signing probe: `healthkit-free-tier-probe.md`. If a brief and the decision log disagree, the decision log wins; flag the brief.

## Signing caveats (free Personal Team)

From the probe and `apple/README.md`:

- The free team gets the HealthKit entitlement for the iPhone app. Profiles expire after 7 days; rebuild to renew. Three sideloaded apps per device.
- The Watch build fails until a physical Watch is registered to the team (`Your team has no devices from which to generate a provisioning profile`). Pair the Watch, enable Developer Mode, confirm `xcrun devicectl list devices` shows it, then rebuild. Until then, build the iPhone app without the embedded Watch app to test on the phone.
- App Groups (widgets, complications, shared cache): unverified on the free team; test first ([spec/50 Q2](../../spec/50-open-questions.md#q2-app-groups-on-the-free-personal-team)).
