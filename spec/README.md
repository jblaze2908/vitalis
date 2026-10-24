# Vitalis spec and design package

Vitalis is one person's health app: a self-hosted Node/TypeScript server (this repo's `app/`) that stores Apple Health data and a strength-training log and serves them over HTTP and MCP, plus an iPhone app and an Apple Watch app (`apple/`). This package is everything a coding agent needs to build the native apps and the server features behind them, one task at a time.

Written 24 Oct 2026 from: the decision log (`Context Intelligence/_Inbox/vitalis-native-app-design.md`), the market research note (`vitalis-fitness-app-market-research.md`), the approved Draft frames, and the code on `main` (server, `d3ca9ab`) and `feat/apple-exporter` (apps).

## The five pillars

Sleep · Apple Watch metrics (heart, activity) · weight (Apple Health import **and** manual, source shown, manual written back to Health) · workouts (strength sets on Watch or iPhone, plus Watch workouts) · calories (logged food against an adaptive target).

## Decided principles

User decisions (binding):

1. **The server computes everything**: scores, verdict, baselines, freshness, trends, targets, paces, muscle heat, PRs. The apps only display server results, cache them for offline use, and send raw data (HealthKit samples through the existing exporter, workouts, food).
2. Locked visual identity **Vital line**: pure black, one red pulse line (#FF5233), Archivo condensed caps for words, Archivo expanded light for numbers, Azeret Mono for labels; red only for the line, the one action and "now". Approved screens are the `V · …` frames exported to [`design/`](design/INDEX.md).
3. Tabs `TODAY · SLEEP · BODY · TRAIN · EAT`; Home order fixed all day; hero = Recovery (Sleep inside it), Activity (steps + active energy), Fuel (calories left, protein), Training due; weight in Body only.
4. Morning digest on the first open after waking.
5. Sleep score = duration vs need, bedtime consistency, efficiency, wake-ups (stages excluded). Recovery = sleep, HRV, resting HR.
6. Workouts logged manually on Watch **or** iPhone; no automatic exercise recognition.

Principles from the research note (adopted): no black-box score (parts always visible against your own usual), every block ends in a next step, no streaks or guilt, sync freshness always visible, fast logging (usual/recent, barcode with fallback, Watch prefill).

Design decisions made in this package are labelled where they appear (e.g. "v1 default, tunable" in [11](11-scoring.md)).

## How to use this package

- **Owner:** read [00-product](00-product.md) and [50-open-questions](50-open-questions.md) (six decisions, each with a default so nothing is blocked).
- **Executor setup:** hand out tasks from [40-tasks](40-tasks.md) in order. Each task names the files to touch, the spec sections and design PNGs to read, acceptance criteria and tests. Give the agent the task text, the common rules at the top of 40, and the linked files.
- **Precedence:** decision log > this `spec/` > `apple/briefs/`. The briefs hold per-screen visual measurements and now defer to this spec for data and behaviour.

## File map

| File | Contents |
|---|---|
| [00-product.md](00-product.md) | Journeys J1–J7, pillars, IA, metric hierarchy, fixed-order Home, digest trigger, product states |
| [10-server-api.md](10-server-api.md) | Every new/changed endpoint: auth scopes, schemas, examples, errors, ETags, pagination; MCP changes |
| [11-scoring.md](11-scoring.md) | v1 formulas: baselines, Sleep score, Recovery, verdict and copy, activity pace, muscle freshness, templates, e1RM, adaptive calories; worked examples; test vectors |
| [12-data-model.md](12-data-model.md) | New SQLite tables/columns/indexes, migration style, compute-on-read with cache, invalidation, retention |
| [20-ios-app.md](20-ios-app.md) | iPhone architecture, screens → frames → endpoints, networking, cache, outbox, stale rules, states, accessibility, HealthKit write-back, widgets |
| [21-watch-app.md](21-watch-app.md) | Watch flows, screens without frames, HealthKit workout session, offline store, WatchConnectivity, phone relay, complications |
| [30-design-system.md](30-design-system.md) | Tokens, fonts, type roles, spacing, components (PulseLine, MuscleMap, ReadingRow, buttons, tab bar), the five rules |
| [40-tasks.md](40-tasks.md) | 35 executor tasks: S-00…S-19 server, I-01…I-12 iPhone, W-01…W-03 Watch and widgets |
| [50-open-questions.md](50-open-questions.md) | Owner decisions left, with recommended defaults |
| [design/INDEX.md](design/INDEX.md) | 35 PNGs (33 approved frames + brand board + locked reference) with frame ids and the endpoint each maps to; screens with no frame |
| `../apple/briefs/` | Per-screen SwiftUI build briefs (visual measurements), revised to the server-computes model |

## Glossary

| Term | Meaning |
|---|---|
| Day | The owner's local calendar day (`VITALIS_TZ`). |
| Night | One sleep period, keyed by the day the sleeper woke up. |
| Usual / typical range | Median and 10th–90th percentile of the 60 days before the day (fewer than 7 days: none). |
| Baseline spread | 1.4826 × median absolute deviation, with a floor; used for z-scores in Recovery. |
| Calibrating | Fewer than 14 nights of history, so a score that needs a baseline shows "Needs N more nights". |
| Recovery band | `ready` ≥ 75, `steady` 60–74, `ease` 45–59, `rest` < 45. |
| Verdict | The headline and one action at the top of Today. |
| Heat | Muscle colour level 0–4: 0 no data, 1 fresh (bone), 2 recovering, 3 partly loaded, 4 loaded (pulse red). |
| Template | Legs, Push or Pull: a muscle group and its exercise list; "due" when all its muscles are fresh. |
| Working set | Any set except a warm-up; only working sets count toward volume, freshness and records. |
| e1RM | Estimated one-rep max, Epley `w × (1 + reps/30)`, 1–12 reps only; always an estimate. |
| Slot | Meal slot: breakfast, lunch, snack, dinner (time windows in [10 §4](10-server-api.md#get-v2today--read)). |
| Usual (food) | The meal eaten most often in a slot over 28 days, at least 3 times. |
| Exporter | The existing iPhone code that sends raw HealthKit samples to `POST /v2/samples` (`apple/Vitalis/SyncEngine.swift`). |
| Outbox | The phone's durable queue of writes (food, workouts, weight, targets) with client UUIDs. |
| WatchPack | Prefill and settings the phone sends to the Watch for offline logging. |
| TodaySnapshot | Subset of `/v2/today` written to the App Group for widgets and complications. |
| PulseLine | The signature red line: past solid, a dip per event, a now-dot, the future dotted. |
| Scopes | Token scopes `ingest` (push only), `read` (read routes + read MCP tools), `write` (everything). |
