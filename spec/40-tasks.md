# 40 · Executor tasks

Thirty-five tasks, in build order. Each one is meant to be handed to a coding agent on its own, with only the files it links. Every task assumes the **common rules** below; paste them with the task if the agent cannot open this file.

## Common rules (apply to every task)

1. **Repository and branch.** Work in the Vitalis repo on the integration branch created by S-00 (`vitalis-app`). Server code is in `app/`, Apple code in `apple/`, this spec in `spec/`.
2. **Server conventions** (from `app/` on `main`): TypeScript ESM, Node ≥ 22.15, `node:sqlite` via `run/one/all/tx` in `app/src/db.ts`, errors as `HttpError` (`app/src/config.ts`), validation with `zod`, Hono routes. No new npm dependency without the owner's approval (the only candidate is in [50 Q1](50-open-questions.md#q1-llm-provider-and-key-for-describe)). Comments: 1–2 lines, the non-obvious why only.
3. **Server tests.** `cd app && npm run build && npm test` (runs `TZ=UTC node --test tests/*.test.mjs` against `dist/`). New tests use the harness in `app/tests/_env.mjs` (`http()`, `call()`, `payload()`, `tokens.createToken()`), one fresh database per test file. No real health data in tests or fixtures; synthetic values only. `npm run typecheck` must pass.
4. **Apple conventions** (from `apple/README.md`, `apple/project.yml`): XcodeGen, Swift 6 strict concurrency, `SWIFT_DEFAULT_ACTOR_ISOLATION: nonisolated` (mark view models `@MainActor`), iOS 18 / watchOS 11, no third-party packages. Regenerate with `cd apple && xcodegen`. Build both schemes and run `VitalisTests` with the commands in `apple/README.md` → "Build and test on a Mac" (simulator, `CODE_SIGNING_ALLOWED=NO`).
5. **Server computes everything.** Apps display server results, cache them, and send raw data. No scoring, baseline, trend, target or verdict logic in Swift ([README](README.md#decided-principles)).
6. **Design.** Only frames in [`spec/design/`](design/INDEX.md) are approved; numbers in them are example data. Tokens and components from [30-design-system.md](30-design-system.md); never hard-code a hex, font name or size outside `VitalisUI`.
7. **Secrets.** Never print, log, commit or embed a token or API key. The write token lives only in the iOS Keychain (`TokenStore`); the LLM key only in the server environment.
8. **Commits.** One commit per task, `<type>: <imperative summary>` under 72 characters (repo history uses `feat:`, `fix:`, `docs:`, `test:`). Do not push unless told.
9. **Done means**: acceptance criteria met, tests added and passing, no new warnings in typecheck/build, and the task's docs touched where it says so.

Sizes: **S** ≈ under half a day, **M** ≈ a day, **L** ≈ two to three days (estimates).

---

## Server

### S-00 · Create the integration branch
- **Goal:** one branch containing the server on `main` and the Apple app on `feat/apple-exporter` plus this spec.
- **Files:** none edited (git only).
- **Inputs:** this file; `git log main`, `git log feat/apple-exporter`.
- **Prerequisite:** the owner has committed `spec/` and the revised `apple/briefs/` on `docs/swiftui-briefs` (they were left uncommitted in the working tree).
- **Steps:** `git checkout -b vitalis-app main`; `git merge --no-ff feat/apple-exporter`; `git merge --no-ff docs/swiftui-briefs` (or the branch holding `spec/`). Resolve conflicts if any (a dry run with `git merge-tree` of `main` and `docs/swiftui-briefs` on 24 Oct 2026 reported none).
- **Acceptance:** `app/src/v2.ts`, `apple/project.yml` and `spec/README.md` all exist on `vitalis-app`; `cd app && npm ci && npm run build && npm test` passes.
- **Tests:** existing suite only.
- **Depends on:** none. **Size:** S.

### S-01 · Schema: new tables and columns
- **Goal:** add every table, column and index in [12 §2](12-data-model.md#2-schema-changes).
- **Files:** `app/src/db.ts`; new `app/tests/schema.test.mjs`.
- **Inputs:** [12-data-model.md](12-data-model.md) §1–2.
- **Steps:** add the `CREATE TABLE IF NOT EXISTS` statements to the existing `db.exec` block; add guarded `ALTER TABLE … ADD COLUMN` for `sleep_nights.wakeups`, `sessions.hk_workout_uuid`, `sessions.template`, `sessions.client_source` using the `hasCodec()` pattern (check `PRAGMA table_info`, tolerate a concurrent add); seed `meta` rows; export `bumpDataVersion()` and `dataVersions(): {data, targets}` helpers.
- **Acceptance:** a fresh database and a database created by the previous code both end with the new schema; running startup twice is a no-op.
- **Tests:** `schema.test.mjs`: open a db, assert columns via `PRAGMA table_info`, assert `meta` rows, call startup code twice. Use `app/tests/fixtures/` style for an "old" db created with the pre-change DDL.
- **Depends on:** S-00. **Size:** S.

### S-02 · Wake-up count in native sleep nights
- **Goal:** fill `sleep_nights.wakeups` from raw sleep segments.
- **Files:** `app/src/v2-derived.ts` (`Derivations.sleep()`), `app/tests/v2.test.mjs` (add cases).
- **Inputs:** [12 §2.1](12-data-model.md#21-columns-added-to-existing-tables); `docs/native-sync.md` → Phase 1 clarifications (sleep grouping, category values: 0 in bed, 1/3/4/5 asleep, 2 awake).
- **Steps:** in the per-night block that writes `sleep_nights`, merge awake (`category_value = 2`) intervals with the existing `merge()`, keep those ≥ 60 s whose span lies between the first asleep start and the last asleep end, count them; add `wakeups` to the INSERT and the `ON CONFLICT … DO UPDATE SET`. Health Auto Export path stays NULL. (Marking reparsed days dirty is done in S-07.)
- **Acceptance:** a night with asleep segments separated by two awake segments has `wakeups = 2`; awake before first sleep or after final wake are not counted; a night with no awake segments has 0 when staged, and `awake_h` stays null as today.
- **Tests:** extend `v2.test.mjs` using its `sleep()` helper.
- **Depends on:** S-01. **Size:** S.

### S-03 · 60-day baselines and robust spread
- **Goal:** one baseline definition for scores, endpoints and MCP.
- **Files:** `app/src/stats.ts`, `app/src/mcp.ts` (text only), `app/tests/stats.test.mjs`, `app/tests/mcp.test.mjs`.
- **Inputs:** [11 §2](11-scoring.md#2-personal-baselines).
- **Steps:** set `BASELINE_DAYS = 60`; add `robustSpread(values, floor)` (1.4826 × MAD with floor) and `MIN_SCORE_DAYS = 14` exports; update the "30 days" wording in `INSTRUCTIONS` and tool descriptions; update tests that assert `baseline_days: 30` with a comment explaining the deliberate change.
- **Acceptance:** `compare()` uses the 60 days before the day; `robustSpread([1,2,3,4,100], 0)` returns 1.4826; MCP texts say 60 days.
- **Tests:** unit cases for `robustSpread`; existing suite green after deliberate updates.
- **Depends on:** S-00. **Size:** S.

### S-04 · Scoring module: sleep, recovery, verdict
- **Goal:** pure functions for [11 §3–5](11-scoring.md#3-sleep-score-0100) with the test vectors.
- **Files:** new `app/src/scoring-config.ts`, `app/src/scoring.ts`; new `app/tests/scoring.test.mjs`.
- **Inputs:** [11-scoring.md](11-scoring.md) §1–5, §9, §10.1–10.4, §10.8.
- **Steps:** implement `sleepNeed()`, `sleepParts()`, `sleepScore()`, `sleepBand()`, part `detail` strings, `hrvPart()`, `rhrPart()`, `recoveryScore()` (weights, renormalisation, min-parts rule, guard), `displayHints()` (arrow/tint), `verdict()` (rule table, labels), `digestHeadline()`, `tonight()`. No SQL; inputs are plain objects. All constants in `scoring-config.ts`.
- **Acceptance:** every vector in §10.1–10.4 passes exactly; stage values never change a result (§10.8); the §3.4 and §4.1 worked examples reproduce (86 · good, 82 · ready).
- **Tests:** table-driven `scoring.test.mjs` importing `../dist/src/scoring.js`.
- **Depends on:** S-03. **Size:** M.

### S-05 · Training analytics module
- **Goal:** pure functions for [11 §7](11-scoring.md#7-training).
- **Files:** new `app/src/training-analytics.ts`; new `app/tests/training-analytics.test.mjs`.
- **Inputs:** [11 §7, §10.5](11-scoring.md#7-training); muscle list `MUSCLES` in `app/src/exercises.ts`; `e1rm()` and `suggest()` in `app/src/training.ts`.
- **Steps:** `muscleLoad(sets, now)`, `heat(L, trainedIn30d)`, `freshness(sets, now)` returning all 17 hyphen slugs with heat/load/days_since, `TEMPLATES` constant, `dueTemplate(freshness, lastTemplateSessions)`, `sessionHeat(sets)`, `weeklySets(sets, weekStart, range)`, `e1rmTrend(points, today)`. Slug helper `toSlug("lower back") = "lower-back"` and back.
- **Acceptance:** §10.5 vectors pass; every function returns 17 keys where muscles are involved; `dueTemplate` returns null when no template is fully fresh.
- **Tests:** table-driven file above.
- **Depends on:** S-00. **Size:** M.

### S-06 · Fuel and activity modules
- **Goal:** pure functions for [11 §6, §8](11-scoring.md#6-activity-ahead--behind-usual-by-now).
- **Files:** new `app/src/fuel.ts`, `app/src/activity.ts`; new `app/tests/fuel.test.mjs`, `app/tests/activity.test.mjs`.
- **Inputs:** [11 §6, §8, §10.6, §10.7](11-scoring.md#8-fuel).
- **Steps:** `weightTrend(daily, seed)`, `monthChange()`, `initialKcal()`, `proteinTarget()`, `stepsTarget()`, `adaptiveKcal({intakes, weights, seed, prev, goal})`; `curveFromSamples(samples, day, tz)` (24 fractions), `usualFractionNow(curves, minuteOfDay)`, `pace(today, expected, kind)`.
- **Acceptance:** §10.6 and §10.7 vectors pass exactly (including trend values to 3 decimals and kcal 2150/2450/2300).
- **Tests:** the two files above.
- **Depends on:** S-00. **Size:** M.

### S-07 · Derived cache and dirty marking
- **Goal:** compute-on-read with a per-day cache, invalidated by ingest and writes ([12 §3](12-data-model.md#3-how-computation-runs)).
- **Files:** new `app/src/derived.ts`; `app/src/v2.ts` (call `markDirty` at the end of `applyV2`'s transaction); `app/src/v2-derived.ts` (expose `touchedDays`); `app/src/ingest.ts` (call `markDirty` for written days); new `app/tests/derived.test.mjs`.
- **Inputs:** [12 §2.2, §3](12-data-model.md#3-how-computation-runs); [11 §1](11-scoring.md#1-days-nights-and-inputs) (feature definitions incl. overnight HRV).
- **Steps:** after `reparse` (`app/src/ingest.ts` `reparse()` and the CLI `reparse --all` in `app/src/cli.ts`), call `markDirty` for every reparsed day; `features(day)` (read inputs, write `daily_derived` feature columns, clear `features_stale`); `scoresFor(day)` (features for the 60-day window + day, call S-04 functions, cache when `day ≤ today−2`); `markDirty(days)` per §3 step 3; `kcalTargetFor(weekStart)` (lazy weekly row, S-06); `trainingState(now)` (S-05 over last 30 days of sets).
- **Acceptance:** posting a v2 batch that changes yesterday's HRV changes yesterday's recovery on the next read; a cached 10-day-old score is not recomputed when nothing changed (assert `scores_at` unchanged); a change to day D marks D…D+60 scores stale; `meta.data_version` increments on each batch.
- **Tests:** `derived.test.mjs` with synthetic v2 batches (copy the `batch()`/`sample()` helpers style from `v2.test.mjs`).
- **Depends on:** S-01, S-02, S-04, S-05, S-06. **Size:** L.

### S-08 · HTTP plumbing and sync status
- **Goal:** shared auth/ETag/error helpers and the `token` block on `/v2/sync/status`.
- **Files:** new `app/src/http.ts`; `app/src/server.ts`; `app/src/v2.ts` (`syncStatus`); new `app/tests/http.test.mjs`; `docs/native-sync.md` (status section).
- **Inputs:** [10 §1, §2](10-server-api.md#1-conventions).
- **Steps:** `requireToken(c, "read"|"write")` (401/403 per §1.2, logs via `logCall`); `withEtag(c, routeKey, compute)` (304 before compute); `jsonError()`; zod body parser with 1 MB limit; mount empty route files `routes/read.ts`, `routes/write.ts`, `routes/food.ts`. Add `token` and `server` blocks to `/v2/sync/status`.
- **Acceptance:** ingest token gets 403 on a new GET; read token 403 on a new POST; a repeated GET with `If-None-Match` returns 304 with no body; `/v2/sync/status` shows `can_write` correctly for all three scopes.
- **Tests:** `http.test.mjs` using a tiny test route.
- **Depends on:** S-01. **Size:** M.

### S-09 · Targets endpoints
- **Goal:** `GET/PUT /v2/targets` ([10 §3](10-server-api.md#3-targets)).
- **Files:** `app/src/routes/write.ts`, `app/src/routes/read.ts`, new `app/src/targets.ts`; new `app/tests/targets.test.mjs`.
- **Inputs:** [10 §3](10-server-api.md#3-targets); [12 §2.4](12-data-model.md#24-targets-keys); [11 §8–9](11-scoring.md#8-fuel).
- **Steps:** read/merge stored keys with computed defaults (`effective`, `suggested`, `is_set`); validate PUT per §3; bump `targets_version`; mark scores stale; recompute this week's kcal row on goal/mode change.
- **Acceptance:** empty install returns defaults (steps 8000, kcal 2200 without weight); after 30 days of synthetic weight 76.4, suggested kcal 2300 and protein 155; invalid values → 422 naming the field.
- **Tests:** `targets.test.mjs`.
- **Depends on:** S-07, S-08. **Size:** M.

### S-10 · Today and digest endpoints
- **Goal:** `GET /v2/today`, `GET /v2/digest` ([10 §4](10-server-api.md#4-today-and-digest)).
- **Files:** `app/src/routes/read.ts`, new `app/src/today.ts`; new `app/tests/today.test.mjs`.
- **Inputs:** [10 §4, §1.6](10-server-api.md#4-today-and-digest); [11 §4–7, §9](11-scoring.md#5-verdict-headline--one-action); design `spec/design/03-home-today.png`, `02-morning-digest.png`.
- **Steps:** assemble bodies from `derived.ts` (S-07), food sums, targets (S-09), activity (S-06), training (S-05); slot windows; pulse window/events; digest availability (night ended ≥ 30 min); freshness block. Builders take `now` (epoch ms) as a parameter; the route passes `Date.now()`, tests pass a fixed time (e.g. 09:41 local on the fixture day) so the clock-dependent rules (verdict rule 1, pace, digest availability, slots) are deterministic.
- **Acceptance:** with the 35-day fixture from `mcp.test.mjs` ("35 days of history, then a short late night") recovery band is `rest` and `verdict.action.kind` is `log_meal`; with a good night and fresh legs the headline is `Train legs hard today`; `training.heat` has 17 keys; `digest.available` false until 30 min after `sleep_end`; ETag changes after a food post.
- **Tests:** `today.test.mjs` (build data with `payload()` from `_env.mjs` plus direct `sets` inserts via MCP `log_sets`).
- **Depends on:** S-09. **Size:** L.

### S-11 · Sleep endpoints
- **Goal:** `GET /v2/sleep`, `GET /v2/sleep/week` ([10 §5](10-server-api.md#5-sleep-and-body)).
- **Files:** `app/src/routes/read.ts`; new `app/tests/sleep-api.test.mjs`.
- **Inputs:** [10 §5](10-server-api.md#get-v2sleepdate--read); [11 §3, §9](11-scoring.md#3-sleep-score-0100); `spec/design/04-sleep-tab.png`.
- **Steps:** night block, parts with detail/flags/weights, stages with the note, tonight, prev/next; week list, avg, bedtime spread.
- **Acceptance:** a night with no in-bed data returns efficiency from sleep start/end; a missing night gives `has_night: false` with `tonight` present; `next_day` null on today.
- **Tests:** file above.
- **Depends on:** S-07, S-08. **Size:** M.

### S-12 · Body endpoint and manual weight
- **Goal:** `GET /v2/body`, `POST /v2/weight`, `DELETE /v2/weight/:id` ([10 §5](10-server-api.md#get-v2bodydate--read)).
- **Files:** `app/src/routes/read.ts`, `app/src/routes/write.ts`, new `app/src/weight.ts`; new `app/tests/body.test.mjs`.
- **Inputs:** [10 §5](10-server-api.md#post-v2weight--write); [12 §2.3](12-data-model.md#23-manual-weight-projection); [11 §8.1](11-scoring.md#81-weight-trend); `spec/design/05-body-tab.png`, `08-log-weight-sheet.png`.
- **Steps:** weight series + trend + latest source; activity + week; vitals via `compare()`; weight post projects into `metric_days` source `Vitalis manual`; idempotent by id; delete re-projects.
- **Acceptance:** posting the same weight id twice leaves one entry; a manual entry and a HealthKit sample with the same value on the same day yield one daily value; `latest.source` is `VITALIS` for manual.
- **Tests:** file above (HealthKit sample via a v2 batch with `HKQuantityTypeIdentifierBodyMass`).
- **Depends on:** S-07, S-08. **Size:** M.

### S-13 · Training read endpoints
- **Goal:** `GET /v2/training`, `/v2/training/sessions`, `/v2/training/sessions/:id` ([10 §6](10-server-api.md#6-training)).
- **Files:** `app/src/routes/read.ts`, `app/src/training.ts` (use `hk_workout_uuid` first in `sessionView`); new `app/tests/training-api.test.mjs`.
- **Inputs:** [10 §6](10-server-api.md#get-v2trainingweek--read); [11 §7](11-scoring.md#7-training); `spec/design/06-train-tab.png`, `09-session-detail-push.png`, `26-state-train-empty.png`.
- **Steps:** week body with heat/muscles/due/stats/weekly sets/sessions (PR tag from records query); cursor pagination; session detail with heat, PR flags, avg bpm.
- **Acceptance:** `empty: true` on a fresh install; a session linked by `hk_workout_uuid` shows that workout's HR even when times don't overlap; pagination returns each session once across pages.
- **Tests:** file above.
- **Depends on:** S-05, S-08. **Size:** M.

### S-14 · Exercise endpoints
- **Goal:** `GET /v2/exercises`, `GET /v2/exercises/:id`, `POST /v2/exercises` ([10 §6](10-server-api.md#get-v2exercisessinceq--read)).
- **Files:** `app/src/routes/read.ts`, `app/src/routes/write.ts`, `app/src/training.ts` (export structured `next`); new `app/tests/exercises-api.test.mjs`.
- **Inputs:** [10 §6](10-server-api.md#get-v2exercisesid--read); `app/src/exercises.ts`; `spec/design/10-exercise-detail-bench-press.png`.
- **Steps:** catalog with hyphen slugs and ETag; `since`; `q`; detail with e1RM trend (S-05), records, structured `next`, last session sets; custom create.
- **Acceptance:** catalog count = seeded count + custom; `since` returns only custom exercises created after it; detail `next.weight_kg` equals the number inside `next.suggestion`.
- **Tests:** file above.
- **Depends on:** S-05, S-08. **Size:** M.

### S-15 · POST /v2/workouts
- **Goal:** idempotent session upsert from Watch or iPhone ([10 §6](10-server-api.md#post-v2workouts--write)).
- **Files:** `app/src/training.ts` (`upsertWorkout`), `app/src/routes/write.ts`; new `app/tests/workouts-api.test.mjs`; `docs/native-sync.md` (replace the "Training (phase 2)" section with a pointer to this endpoint).
- **Inputs:** [10 §6](10-server-api.md#post-v2workouts--write); existing `logSets`, `checkSet`, `resolveExercise`.
- **Steps:** zod schema; one `tx()`; insert/update/delete sets; session fields; `markDirty`; response with session view, accepted counts, PRs.
- **Acceptance:** posting the same body three times creates one session and N sets; changing one set's reps updates it; `deleted: true` removes it from reads; a set id from another session → 409 and nothing written; unclear exercise name → 422 with candidates and nothing written.
- **Tests:** file above.
- **Depends on:** S-13. **Size:** M.

### S-16 · Food log endpoints
- **Goal:** food day, quick, entries, deletes, saved meals ([10 §7](10-server-api.md#7-food)).
- **Files:** new `app/src/food.ts`, `app/src/routes/food.ts`; new `app/tests/food-api.test.mjs`.
- **Inputs:** [10 §7](10-server-api.md#get-v2fooddaydate--read) (day, quick, entries, deletes, saved); [12 §2.2](12-data-model.md#22-new-tables); [11 §8.2](11-scoring.md#82-calorie-target); `spec/design/07-eat-tab.png`, `13-quick-add-food.png`, `18-eat-just-added.png`, `27-state-eat-empty.png`.
- **Steps:** day assembly with targets; slot windows; usual/recent/saved rules; idempotent batch insert; meal delete; `markDirty`.
- **Acceptance:** three identical posts → one entry; `DELETE /v2/food/meals/:meal_id` removes every entry of that add; the usual appears only after 3 occurrences within 28 days; `kcal_left` negative sets `over: true`.
- **Tests:** file above.
- **Depends on:** S-09. **Size:** M.

### S-17 · Food search and barcode (Open Food Facts proxy)
- **Goal:** `GET /v2/food/search`, `GET/PUT /v2/food/barcode/:code` ([10 §7](10-server-api.md#get-v2foodsearchqpage--read)).
- **Files:** new `app/src/off.ts`, `app/src/routes/food.ts`; new `app/tests/off.test.mjs`; `.env.example` (`VITALIS_CONTACT_EMAIL`).
- **Inputs:** [10 §7](10-server-api.md#get-v2foodbarcodecode--read) incl. the Open Food Facts facts and limits; [12 §2.2, §4](12-data-model.md#4-retention).
- **Steps:** `fetch` with `User-Agent: Vitalis/<version> (<VITALIS_CONTACT_EMAIL>)`, 5 s `AbortSignal.timeout`; token buckets (8 search/min, 12 product/min); caches; local-first merge; normalise nutriments to `per_100g` and `serving`; user barcodes.
- **Acceptance:** with `fetch` stubbed (inject a fetch function; tests never hit the network), a cached query makes no second call within 7 days; the 9th search in a minute returns local results with `remote: "rate_limited"`; an OFF `status: 0` response returns `found: false` and is cached for a day; a user barcode wins over OFF.
- **Tests:** `off.test.mjs` with an injected fake fetch.
- **Depends on:** S-16. **Size:** M.

### S-18 · Describe (server-side LLM parse)
- **Goal:** `POST /v2/food/describe` behind a `MealParser` interface ([10 §7](10-server-api.md#post-v2fooddescribe--write)).
- **Files:** new `app/src/describe.ts`, `app/src/routes/food.ts`; new `app/tests/describe.test.mjs`; `.env.example`.
- **Inputs:** [10 §7 describe](10-server-api.md#post-v2fooddescribe--write); [50 Q1](50-open-questions.md#q1-llm-provider-and-key-for-describe).
- **Steps:** interface + `FixtureParser` (deterministic: splits on commas/"and", looks up a small built-in table of 20 common dishes with portions, else 300 kcal "estimate"); config switch `VITALIS_DESCRIBE`; zod output validation; per-token hourly limit; timeouts. Implement the provider adapter only if Q1 has been answered and the dependency approved; otherwise ship `off` + `fixture` and leave a clearly named stub that throws `HttpError(503)`.
- **Acceptance:** `VITALIS_DESCRIBE=off` → 503 `unavailable`; `fixture` returns items with `estimate: true` and totals equal to the item sums; 31st call in an hour → 429; nothing is written to the database except a `calls` row.
- **Tests:** file above (fixture mode only; no network).
- **Depends on:** S-16. **Size:** M.

### S-19 · MCP parity, docs and read latency bench
- **Goal:** agents read the same numbers; docs and measurements updated ([10 §8](10-server-api.md#8-mcp-tools)).
- **Files:** `app/src/mcp.ts`, `app/tests/mcp.test.mjs`, `docs/api.md`, `docs/native-sync.md`, `app/bench/read-latency.mjs`, `app/bench/README.md`.
- **Inputs:** [10 §8](10-server-api.md#8-mcp-tools); [12 §3](12-data-model.md#3-how-computation-runs) (latency target).
- **Steps:** extend `get_brief`, `get_metrics`, `get_sleep`, `get_training_summary`; add `get_today`, `get_scores`, `get_food_day`, `log_food` (write), `get_targets`; update the tool-list assertion; document every new HTTP route in `docs/api.md`; extend the bench to time `/v2/today`, `/v2/training`, `/v2/food/day` on the one-year synthetic dataset and record results in `app/bench/results/`.
- **Acceptance:** `get_today` equals the `GET /v2/today` body for the same day (deep-equal minus `generated_at`); `verdict.call` mapping per [11 §5](11-scoring.md#5-verdict-headline--one-action); bench shows p95 for each route (target < 50 ms; if missed, note it in `app/bench/README.md` with the measured number, do not hide it).
- **Tests:** updated `mcp.test.mjs`.
- **Depends on:** S-10 … S-18. **Size:** M.

---

## iPhone

### I-01 · First Mac build and the VitalisUI design system
- **Goal:** the exporter compiles; a `VitalisUI` library with tokens, fonts, type roles and the simple components.
- **Files:** `apple/VitalisKit/Package.swift`, new `apple/VitalisKit/Sources/VitalisUI/**` (Tokens, Fonts, TypeRoles, PrimaryButton, SecondaryButton, MonoLabel, ReadingRow, TabBar, StatusRow, ScreenHeader, ProgressTrack, RangeBar, WeekBars, Toast, Previews/Fixtures), `apple/project.yml` (link `VitalisUI` to both apps), font and licence files.
- **Inputs:** [30-design-system.md](30-design-system.md) (all sections except PulseLine and MuscleMap); `spec/design/00-brand-board.png`, `01-locked-identity-reference.png`, `03-home-today.png`; `apple/README.md`.
- **Steps:** build both schemes first and fix compile errors in the existing exporter (keep behaviour); add the target; bundle Archivo and Azeret Mono with their OFL texts; register fonts in both apps; implement components with previews.
- **Acceptance:** the checklist items in [30](30-design-system.md#acceptance-checklist) that don't mention PulseLine/MuscleMap; `VitalisTests` passes.
- **Tests:** a unit test that both font families register and that every colour token resolves; existing tests.
- **Depends on:** S-00. **Size:** L.

### I-02 · PulseLine and MuscleMap
- **Goal:** the two signature components.
- **Files:** `apple/VitalisKit/Sources/VitalisUI/PulseLine.swift`, `MuscleMap/MuscleMap.swift`, generated `MuscleMap/MuscleMapPaths.swift`, `MuscleMap/LICENSE-react-native-body-highlighter.txt`, new `apple/scripts/gen-muscle-map.py`; tests.
- **Inputs:** [30 → PulseLine, MuscleMap](30-design-system.md#pulseline); `apple/briefs/assets/muscle-map-paths.json`; `spec/design/03-home-today.png`, `06-train-tab.png`, `31-watch-set-entry.png`, `33-watch-summary.png`.
- **Steps:** PulseLine variants (phone/watch/widget/progress) taking `window/now/events` in seconds or pre-mapped fractions; MuscleMap with `heat: [Muscle: Int]` keyed by hyphen slugs; generator converting SVG arcs to cubics; MIT notice.
- **Acceptance:** previews match the frames listed; all 17 muscles render at every heat; generated paths fall inside the viewBox.
- **Tests:** generator output test (17 muscles present, bounding boxes inside `[20,150,1408,1215]`); PulseLine mapping test (x clamps to 0…1).
- **Depends on:** I-01. **Size:** M.

### I-03 · API client, models, response cache and outbox
- **Goal:** typed access to every endpoint, offline cache and durable writes ([20 §5](20-ios-app.md#5-networking-cache-and-outbox)).
- **Files:** `apple/VitalisKit/Sources/VitalisKit/VitalisAPI.swift`, `APIModels/*.swift`, `ResponseCache.swift`, `Outbox.swift`, refactor shared request code out of `APIClient.swift`; `apple/VitalisTests/APIModelTests.swift`, `OutboxTests.swift`, `ResponseCacheTests.swift`, `VitalisTests/Fixtures/api/*.json`.
- **Inputs:** [10-server-api.md](10-server-api.md) (every JSON example becomes a fixture); [20 §5–6](20-ios-app.md#5-networking-cache-and-outbox).
- **Steps:** models per endpoint with snake-case decoding; `If-None-Match`/304; error enum from `code`; cache files with protection and pruning; Outbox actor with ordering, backoff, failure buckets, `NWPathMonitor` trigger.
- **Acceptance:** every fixture decodes; a 304 returns the cached body; Outbox replays in order after a simulated crash and drops nothing; 401 halts the queue.
- **Tests:** files above, with a stub `URLProtocol`.
- **Depends on:** I-01, S-08 (shapes from spec are enough; no live server needed). **Size:** L.

### I-04 · App shell, router and deep links
- **Goal:** the five-tab shell replacing the current root `TabView`.
- **Files:** `apple/Vitalis/VitalisApp.swift`, new `apple/Vitalis/App/Router.swift`, `DeepLinks.swift`, placeholder screens per tab, `apple/Vitalis/Info.plist` (`UIUserInterfaceStyle = Dark`, URL scheme `vitalis`).
- **Inputs:** [20 §2–3](20-ios-app.md#2-architecture); [30 → TabBar](30-design-system.md#tabbar-custom); `spec/design/03-home-today.png`.
- **Steps:** custom TabBar, router state, deep-link parsing for every link in 20 §3, Settings entry point, setup gate (`setupCompleted`).
- **Acceptance:** each deep link opens its destination; existing Sync/Settings reachable from Settings; dark only.
- **Tests:** deep-link parsing unit test.
- **Depends on:** I-01. **Size:** S.

### I-05 · Setup flow
- **Goal:** five onboarding screens wrapping the existing connect/authorise/backfill code.
- **Files:** new `apple/Vitalis/Screens/Setup/*.swift`, `apple/Vitalis/Stores/SetupStore.swift`, `apple/Vitalis/AppModel.swift` (share types), `apple/Vitalis/Info.plist` (`NSHealthUpdateUsageDescription`), `apple/README.md` (write access note).
- **Inputs:** [20 §4 Setup](20-ios-app.md#setup-first-run), [20 §8](20-ios-app.md#8-healthkit-write-back); [10 §2, §3](10-server-api.md#2-get-v2syncstatus-changed); `spec/design/19-setup-welcome.png` … `23-setup-targets.png`; [apple/briefs/03-tabs-and-flows.md → Setup](../apple/briefs/03-tabs-and-flows.md#setup--onboarding).
- **Steps:** per 20 §4; Continue gated on `token.can_write`; progress percent rule; targets PUT.
- **Acceptance:** 401, unreachable and read-only token each show their inline error and block Continue; the Health sheet lists the new share types; backfill continues while on Targets; Finish lands on Today and setup never shows again unless the token is cleared.
- **Tests:** SetupStore unit tests with a stub API.
- **Depends on:** I-03, I-04, I-02. **Size:** M.

### I-06 · Sync, Settings and stale states
- **Goal:** Settings, Sync, token-rejected and the stale rules.
- **Files:** `apple/Vitalis/Screens/Settings/*.swift`, restyled `SyncView.swift`/`SettingsView.swift`, `apple/Vitalis/Stores/SyncStore.swift`.
- **Inputs:** [20 §4 Settings and Sync, §6](20-ios-app.md#settings-and-sync); `spec/design/24-state-today-sync-stale.png`, `25-state-sync-token-rejected.png`, `28-settings.png`.
- **Steps:** settings rows incl. targets edit via `PUT /v2/targets`; Outbox + Watch-held counts; token replace; `firstAuthFailureAt`; a shared `StaleState` model consumed by Today (I-07).
- **Acceptance:** forcing a 401 shows the rejected state with real counts; Replace token + Try again resumes and clears it; no token value appears on screen or in logs; each stale cause shows its copy.
- **Tests:** StaleState unit tests for every row of the 20 §6 table.
- **Depends on:** I-03, I-04. **Size:** M.

### I-07 · Today and the morning digest
- **Goal:** Home and digest from `/v2/today` and `/v2/digest`.
- **Files:** `apple/Vitalis/Screens/Today/*.swift`, `apple/Vitalis/Stores/TodayStore.swift`.
- **Inputs:** [20 §4 Today, Morning digest](20-ios-app.md#today); [10 §4](10-server-api.md#4-today-and-digest); [apple/briefs/01-today-and-digest.md](../apple/briefs/01-today-and-digest.md); `spec/design/02-morning-digest.png`, `03-home-today.png`, `24-state-today-sync-stale.png`.
- **Steps:** render fixed order; action routing; digest trigger and dismissal; refresh triggers; states (loading, cached, calibrating, missing, stale, empty training/fuel); write `TodaySnapshot` after each fetch (consumed by W-03).
- **Acceptance:** brief 01 checklist; with fixtures the screen matches the frames within 2 pt; no arithmetic in views (review: only formatting).
- **Tests:** TodayStore tests (digest shown once per day; action routing per `action.kind`).
- **Depends on:** I-02, I-06. **Size:** L.

### I-08 · Sleep tab, Body tab and Log weight
- **Goal:** Sleep and Body screens and the weight sheet with HealthKit write.
- **Files:** `apple/Vitalis/Screens/Sleep/*.swift`, `Screens/Body/*.swift`, `apple/Vitalis/Health/HealthWriter.swift` (weight), stores.
- **Inputs:** [20 §4 Sleep, Body](20-ios-app.md#sleep); [10 §5](10-server-api.md#5-sleep-and-body); [20 §8](20-ios-app.md#8-healthkit-write-back); [apple/briefs/03-tabs-and-flows.md](../apple/briefs/03-tabs-and-flows.md#sleep-tab--3wxlux5k-j) Sleep, Body, Log weight; `spec/design/04-sleep-tab.png`, `05-body-tab.png`, `08-log-weight-sheet.png`.
- **Steps:** day navigation, week bars, Remind me notification; weight chart from `series`; sheet saves HealthKit sample (toggle on) and enqueues `POST /v2/weight`.
- **Acceptance:** brief 03 Sleep/Body acceptance; toggle off writes no HealthKit sample but the server entry appears; Undo (sheet) deletes both.
- **Tests:** store tests; HealthWriter tested behind a protocol with a fake store.
- **Depends on:** I-07. **Size:** M.

### I-09 · Train tab, session detail, exercise detail
- **Goal:** training screens from the read endpoints.
- **Files:** `apple/Vitalis/Screens/Train/*.swift`, `Stores/TrainStore.swift`.
- **Inputs:** [20 §4 Train](20-ios-app.md#train); [10 §6](10-server-api.md#6-training); [apple/briefs/03-tabs-and-flows.md](../apple/briefs/03-tabs-and-flows.md#train-tab--d68bo9or4s) Train, Session detail, Exercise detail; `spec/design/06-train-tab.png`, `09-session-detail-push.png`, `10-exercise-detail-bench-press.png`, `26-state-train-empty.png`, `11-workout-start-choice.png`.
- **Steps:** week view, sessions paging, detail screens, e1RM chart from `points`, start-choice sheet with `startWatchApp` and remembered choice.
- **Acceptance:** frames match with fixtures; Start on Watch launches the Watch app in a paired simulator; the sheet remembers the choice.
- **Tests:** store tests.
- **Depends on:** I-07. **Size:** M.

### I-10 · Eat tab, quick add, undo and HealthKit nutrition
- **Goal:** food logging core.
- **Files:** `apple/Vitalis/Screens/Eat/*.swift`, `Stores/EatStore.swift`, `Health/HealthWriter.swift` (food).
- **Inputs:** [20 §4 Eat](20-ios-app.md#eat), [20 §8](20-ios-app.md#8-healthkit-write-back); [10 §7](10-server-api.md#7-food) day/quick/entries/deletes; brief 03 Eat, Quick add, Just added, Empty; `spec/design/07-eat-tab.png`, `13-quick-add-food.png`, `18-eat-just-added.png`, `27-state-eat-empty.png`.
- **Steps:** day view with navigation; usual one-tap; quick add; entries via Outbox with `meal_id`; toast + Undo (outbox drop or DELETE); HealthKit correlations written and deleted.
- **Acceptance:** one tap on the usual logs it and writes HealthKit samples; Undo removes both; offline adds show `WAITING TO SYNC` and sync later exactly once.
- **Tests:** store tests with a stub API; HealthWriter fake.
- **Depends on:** I-07. **Size:** M.

### I-11 · Food search, scan, not found, describe
- **Goal:** the other three ways to add food.
- **Files:** `apple/Vitalis/Screens/Eat/Search*.swift`, `Scan*.swift`, `Describe*.swift`, `apple/Vitalis/Info.plist` (`NSCameraUsageDescription`).
- **Inputs:** [20 §4 Eat](20-ios-app.md#eat); [10 §7](10-server-api.md#get-v2foodsearchqpage--read) search/barcode/describe; brief 03 Search, Describe, Scan; `spec/design/14-food-search.png` … `17-scan-not-found.png`.
- **Steps:** debounced search with remote-status line; VisionKit scanner; not-found options incl. label photo (Vision text recognition → prefilled form); `PUT` barcode; describe with portion factors; Describe hidden on 503.
- **Acceptance:** found and not-found paths work against fixtures; Describe 503 hides the tile; no request is made per keystroke (one in flight, 500 ms debounce).
- **Tests:** search debounce test; parser for label text (kcal/protein/carbs/fat extraction) with sample strings.
- **Depends on:** I-10. **Size:** M.

### I-12 · Workout logging on iPhone
- **Goal:** start-to-finish logging on the phone ([20 §4](20-ios-app.md#iphone-workout-logging)).
- **Files:** `apple/Vitalis/Screens/Workout/*.swift`, `Stores/LiveSessionStore.swift`, `Health/HealthWriter.swift` (workout via `HKWorkoutBuilder`).
- **Inputs:** [20 §4 iPhone workout logging](20-ios-app.md#iphone-workout-logging); [10 §6](10-server-api.md#post-v2workouts--write); brief 03 iPhone logging; `spec/design/12-workout-logging-iphone.png`, `11-workout-start-choice.png`.
- **Steps:** live session persisted on every change; prefill from exercise detail; check → set + rest + Outbox upsert; add exercise via `GET /v2/exercises?q=`; Finish saves `HKWorkout` and posts; read-only when a Watch session is live.
- **Acceptance:** killing the app mid-session loses no set; the current row's check is the only red element; finishing creates one server session whose sets equal the table; `hk_workout_uuid` is set.
- **Tests:** LiveSessionStore tests (persistence, prefill, rest timer math from end date).
- **Depends on:** I-09, S-15 shapes. **Size:** L.

---

## Watch and widgets

### W-01 · Watch logger core
- **Goal:** Start, Set entry, Rest, Summary with a HealthKit session and the local store ([21 §2.1–2.3, §2.8, §4, §5](21-watch-app.md#2-screens-and-flows)).
- **Files:** `apple/VitalisWatch/**` (replace the placeholder), `apple/VitalisWatch/Info.plist` (usage strings, `WKBackgroundModes` `workout-processing`), `apple/VitalisKit/Sources/VitalisKit/WatchMessages.swift`.
- **Inputs:** [21-watch-app.md](21-watch-app.md); [apple/briefs/02-watch-logger.md](../apple/briefs/02-watch-logger.md); `spec/design/30-watch-start.png` … `33-watch-summary.png`; [30 → PulseLine/MuscleMap watch variants](30-design-system.md#pulseline).
- **Steps:** workout session lifecycle and recovery; Crown editing with server step; prefill from `WatchPack`; durable per-session JSON; rest ring shape; summary with catalog lighting until `result` arrives.
- **Acceptance:** 21 §7 items for logging, Crown, rest and crash recovery (simulator acceptable except double tap).
- **Tests:** unit tests for the local store (atomic write, recovery) and rest timing math in `VitalisKit`.
- **Depends on:** I-02. **Size:** L.

### W-02 · Watch screens without frames and phone relay
- **Goal:** live metrics, handoff, add exercise, end; WatchConnectivity both ways; phone posts to the server.
- **Files:** `apple/VitalisWatch/Screens/{LiveMetrics,Handoff,AddExercise,EndWorkout}.swift`, `apple/VitalisWatch/WatchSessionDelegate.swift`, `apple/Vitalis/Watch/PhoneSessionDelegate.swift`, `apple/Vitalis/Watch/WatchPackBuilder.swift`.
- **Inputs:** [21 §2.4–2.7, §6](21-watch-app.md#24-live-metrics-no-frame--specify-in-words); [10 §6](10-server-api.md#post-v2workouts--write); [20 §5.3](20-ios-app.md#53-outbox-durable-writes).
- **Steps:** the four screens as specified in words; message enum; `transferUserInfo` sessions → phone Outbox → `ack`; `result` relay; `WatchPack` via application context; catalog via `transferFile`; `plan` and `sessionState`.
- **Acceptance:** airplane-mode test in 21 §7 passes (each set once on the server, prune only after ack); summary swaps to server heat/PR when `result` arrives; PR description lists the four unframed screens for design review.
- **Tests:** encode/decode round-trip tests for every message; PhoneSessionDelegate test with a fake Outbox (ack only after persist).
- **Depends on:** W-01, I-03, S-15. **Size:** L.

### W-03 · Widgets and complications
- **Goal:** iOS widgets and Watch complications from `TodaySnapshot`.
- **Files:** new targets `VitalisWidgets` (iOS) and `VitalisWatchWidgets` (watchOS) in `apple/project.yml`, their sources, App Group entitlements for app, Watch app and both extensions.
- **Inputs:** [20 §9](20-ios-app.md#9-widgets-and-the-app-group); [21 §3](21-watch-app.md#3-complications-frame-34); [apple/briefs/03-tabs-and-flows.md → Widgets](../apple/briefs/03-tabs-and-flows.md#widgets--ldpxhnsr9k); `spec/design/29-widgets-home-lock.png`, `34-watch-face-complications.png`; [50 Q2](50-open-questions.md#q2-app-groups-on-the-free-personal-team).
- **Steps:** first verify App Group provisioning on the owner's team (if it fails, stop and report; do not work around it); snapshot read; families; deep links; complication transfer with budget fallback.
- **Acceptance:** all families render from a fixture snapshot; widgets update within one reload after a meal is logged; missing snapshot shows `–`.
- **Tests:** snapshot decoding test; timeline provider test with a fixture file.
- **Depends on:** I-07, W-02. **Size:** M.
