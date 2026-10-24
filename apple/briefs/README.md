# Vitalis SwiftUI build briefs

Build specs for the Vitalis iPhone + Apple Watch app in the locked **Vital line** identity. Each brief tells a coding agent (Claude or Codex, on a Mac with Xcode) what to build, with exact tokens, components, data sources, states, interactions and an acceptance checklist. Anything not decided is marked **TBD** with what must be decided. Do not fill a TBD with an invented endpoint, number or formula. Stop and ask, or build the seam and leave a `// TBD(<brief>#<item>)` marker.

Written 24 Oct 2026 from the decision log, the approved Draft frames and the code on `feat/apple-exporter` (app) and `main` (server).

## Files

| File | Covers |
|---|---|
| [00-design-system.md](00-design-system.md) | Tokens, fonts, type roles, spacing, shared components (buttons, ReadingRow, MonoLabel, TabBar, PulseLine, MuscleMap), brand rules, accessibility, previews |
| [01-today-and-digest.md](01-today-and-digest.md) | Home (Today), morning digest, Recovery and Sleep score data model, sources, states |
| [02-watch-logger.md](02-watch-logger.md) | watchOS strength logger, rest timer, summary, complications, workout session, offline queue, transfer to iPhone |
| [03-tabs-and-flows.md](03-tabs-and-flows.md) | Sleep, Body, Train (incl. iPhone set table), Eat (quick add, search, describe, scan), setup, sync states, Settings, widgets |
| [assets/muscle-map-paths.json](assets/muscle-map-paths.json) | SVG path data for the muscle map (MIT, see 00 → MuscleMap) |

## Build order

Each step should build, run and pass its acceptance checklist before the next starts.

1. **Design system** (00). New `VitalisUI` library target in the existing `VitalisKit` package (iOS 18 + watchOS 11 already declared). Fonts, tokens, components, previews. No app screens yet.
2. **App shell** (00 → TabBar, 03 → Settings). Replace the current root `TabView { SyncView; SettingsView }` in `Vitalis/VitalisApp.swift` with the custom five-tab shell (TODAY · SLEEP · BODY · TRAIN · EAT). The existing Sync screen moves under Settings → Sync and is restyled. The `SyncEngine` / `AppModel` pipeline stays as is.
3. **Setup and sync states** (03). Onboarding wraps the existing connect / authorize / backfill code. Needed before any screen has real data.
4. **Today + digest** (01).
5. **Tabs and flows** (03): Sleep, Body, Train, Eat.
6. **Watch logger** (02). Can run in parallel with step 5 once step 1 is done.
7. **Widgets and complications** (03, 02). Last, because they need an App Group (see the signing notes).

## How to use a brief

- Read 00 first, every time. Every screen uses its tokens and components. Never hard-code a hex value, font name or size in a screen.
- Implement against the linked frames. Frame HTML is the measurement source: sizes in the briefs are already converted to points (phone frames are 1x at 390×844 pt; Watch frames are @2x at 416×496 px = 208×248 pt, so halve every Watch number in the HTML).
- All numbers in the frames are **example data**. Never ship them as defaults.
- Each brief ends with an acceptance checklist. Tick every line against a running build (simulator is fine unless the line says device) and a SwiftUI preview.
- After any change: build both schemes, run `VitalisTests`. Commands are in `apple/README.md`.

## Project facts the briefs rely on

From `apple/README.md` and `apple/project.yml` on `feat/apple-exporter`:

- XcodeGen project `Vitalis`. Targets: `Vitalis` (iOS app), `VitalisWatch` (watchOS app, embedded), `VitalisTests`. Local package `VitalisKit`.
- Swift 6, `SWIFT_STRICT_CONCURRENCY: complete`, `SWIFT_DEFAULT_ACTOR_ISOLATION: nonisolated`. So every view model and observable store needs an explicit `@MainActor`.
- iOS 18.0, watchOS 11.0. No third-party dependencies. Keep it that way: nothing in these briefs needs a package.
- Bundle ids `$(BUNDLE_PREFIX).vitalis` and `$(BUNDLE_PREFIX).vitalis.watchkitapp`, signing from the ignored `Config/Signing.xcconfig`.
- The iPhone app already exports every readable HealthKit sample to `POST /v2/samples` (`SyncEngine` actor, anchors, idempotent batches) and reads `GET /v2/sync/status`. The write token lives in Keychain (`TokenStore`, service `Vitalis.API`).
- **Not yet compiled.** The exporter was written on Linux. The first Mac build may need fixes before any brief work.
- The Watch app is a placeholder screen ("Workouts coming soon").

## Server reality (read before any data work)

Routes that exist on `main` (`app/src/server.ts`): `GET /health`, `POST /ingest`, `POST /v2/samples`, `GET /v2/sync/status`, `POST /mcp`. Nothing else.

- **No HTTP read route** for scores, sleep, metrics, workouts or a brief. Those reads exist only as MCP tools on `/mcp` (`get_brief`, `get_sleep`, `get_metrics`, `list_workouts`, `get_workout`, `get_exercise_history`, `get_training_summary`, `find_exercises`, `get_freshness`). See `docs/api.md`.
- **Training routes are specified but not implemented.** `docs/native-sync.md` → "Training (phase 2)" describes `GET/POST /v2/exercises` and `GET/POST /v2/workouts`. They are absent from `server.ts`.
- **No food code at all** on the server.
- **No numeric score.** `get_brief` returns a rule-based `verdict.call` (`easy · as_planned_no_records · normal · good · unknown`), not a 0–100 Recovery or Sleep score.
- The cheapest server integration is HealthKit itself: anything the app **writes** to HealthKit (weight, meals, Watch workouts) is exported by the existing `SyncEngine` with no new server code.

## Design source

- Draft canvas **"Vitalis — Design v2"**, id `3H9qPgAkyt` (Draft MCP: `get_frame`, `get_frame_screenshot`). Canvas page URL: **TBD** (no page URL is recorded; frame renders are at `https://draft.jaivardhansingh.com/i/<frame id>.png?scale=2`).
- Only frames named `V · …` are approved, plus the brand board **"Vitalis identity · Brand system (Vital line)"** (`fDbT_3oo7i`). The board's hexes are older; the LOCKED values in 00 win.
- Everything else on the canvas (J1–J7, Concepts, Options, Home A–E, Watch v1/v2, Identity A–C, tweaks 1–4) is history. Do not build from it.

### Approved frames

| Frame | Id | Brief |
|---|---|---|
| V · Morning digest | `kh6EtZFCP9` | 01 |
| V · Home (Today) | `PwXZkuGWcu` | 01 |
| V · State · Today, sync stale | `Z6akLUWcKH` | 01, 03 |
| V · Watch start @2x | `kNA_vRK_cy` | 02 |
| V · Watch set entry @2x | `pCSw4PpAhl` | 02 |
| V · Watch rest @2x | `AIJAljEgAy` | 02 |
| V · Watch summary @2x | `k_nhjKQwwv` | 02 |
| V · Watch face @2x | `9KeK3X1BI1` | 02 |
| V · Sleep tab | `3WxLux5k-j` | 03 |
| V · Body tab | `SRN5GTWmV2` | 03 |
| V · Train tab | `d68BO9oR4S` | 03 |
| V · Eat tab | `BwU_mhJYzc` | 03 |
| V · Workout start: Watch or iPhone | `3qVL-kZTgZ` | 03 |
| V · Workout logging on iPhone | `7v36M3Kqfq` | 03 |
| V · Log weight sheet | `fW4EJo7EKL` | 03 |
| V · Quick add food | `8kBom9fyeU` | 03 |
| V · Session detail: Push | `u9QwaxL_dQ` | 03 |
| V · Exercise detail: Bench press | `SimAaL4Zws` | 03 |
| V · Food search | `eI_8DOJ_cz` | 03 |
| V · Describe & confirm | `LJ3iovmSnT` | 03 |
| V · Barcode scan | `SRVfnL_In1` | 03 |
| V · Scan not found | `sBdU_XEO7O` | 03 |
| V · Eat tab, just added | `3T4bhbTv67` | 03 |
| V · Setup · Welcome | `iU0mdElwnO` | 03 |
| V · Setup · Connect server (1 of 4) | `gi1tdbhnmF` | 03 |
| V · Setup · Health access (2 of 4) | `_YkjyAR57M` | 03 |
| V · Setup · Reading your history (3 of 4) | `ufOqf8gNFu` | 03 |
| V · Setup · Targets (4 of 4) | `uNuXYF1h84` | 03 |
| V · State · Sync, token rejected | `l4ps-S20fp` | 03 |
| V · State · Train, no workouts yet | `4t-ld-gF6e` | 03 |
| V · State · Eat, nothing logged yet | `fk2O2KyeR-` | 03 |
| V · Settings | `ZlARNorqzI` | 03 |
| V · Widgets · Home & Lock Screen | `lDPxhnSr9k` | 03 |
| Vitalis identity · Brand system (Vital line) | `fDbT_3oo7i` | 00 |
| Component `vt-muscle-map` | (component) | 00 |

## Decision log

The plan of record is the Obsidian note `Context Intelligence/_Inbox/vitalis-native-app-design.md` (LOCKED identity, metric hierarchy, digest, Home E order, sleep score parts, phone + Watch logging, weight sources). Market research: `vitalis-fitness-app-market-research.md`. Free-team signing probe: `healthkit-free-tier-probe.md`. If a brief and the decision log disagree, the decision log wins; flag the brief.

## Signing caveats (free Personal Team)

From the probe and `apple/README.md`:

- The free team gets the HealthKit entitlement for the iPhone app. Profiles expire after 7 days; rebuild to renew. Three sideloaded apps per device.
- The Watch build fails until a physical Watch is registered to the team (`Your team has no devices from which to generate a provisioning profile`). Pair the Watch, enable Developer Mode, confirm `xcrun devicectl list devices` shows it, then rebuild. Until then, build the iPhone app without the embedded Watch app to test on the phone.
- App Groups (widgets, complications, shared snapshot): **TBD** whether the free team can provision them. Test on the free team before building on it.
