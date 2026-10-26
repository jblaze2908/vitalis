import { test } from "node:test";
import assert from "node:assert/strict";
import { addDays, all, body, call, http, mcp, one, payload, tokens } from "./_env.mjs";

const ingestTok = tokens.createToken("phone", "ingest").token;
const readTok = tokens.createToken("reader", "read").token;
const writeTok = tokens.createToken("coach", "write").token;
const DAY = "2026-10-09";

test("a fresh install answers honestly: no data, no verdict, no sync", async () => {
  const r = await call(readTok, "get_brief", { day: DAY });
  assert.equal(r.isError, false, r.text);
  assert.equal(r.data.verdict.call, "unknown");
  assert.equal(r.data.freshness.last_sync, null);
  assert.equal(r.data.sleep.missing, true);
  assert.equal(typeof r.data.summary, "string");
});

test("tool lists follow the token's scope; ingest tokens and foreign origins can't use /mcp", async () => {
  const names = async (t) => (await mcp(t, "tools/list")).msg.result.tools.map((x) => x.name).sort();
  // S-19 added get_today, get_scores, get_food_day, get_targets (read) and log_food (write).
  const reads = ["find_exercises", "get_brief", "get_exercise_history", "get_food_day", "get_freshness", "get_metrics", "get_scores", "get_sleep", "get_targets",
    "get_today", "get_training_summary", "get_workout", "list_workouts"];
  assert.deepEqual(await names(readTok), reads);
  assert.deepEqual(await names(writeTok), [...reads, "create_exercise", "delete_food", "edit_set", "edit_split", "edit_workout", "log_food", "log_saved_meal", "log_sets", "log_weight", "save_meal", "set_targets"].sort());
  const tools = (await mcp(readTok, "tools/list")).msg.result.tools;
  assert.ok(tools.every((t) => t.annotations?.readOnlyHint === true && t.outputSchema));
  const bad = await mcp(ingestTok, "tools/list");
  assert.equal(bad.status, 401);
  assert.match(bad.text, /only push data/);
  assert.equal((await mcp(null, "tools/list")).status, 401);
  const foreign = await http("POST", "/mcp", { token: readTok, headers: { origin: "https://evil.example.net", accept: "application/json, text/event-stream" }, json: { jsonrpc: "2.0", id: 1, method: "tools/list" } });
  assert.equal(foreign.status, 403);
  const init = await mcp(readTok, "initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "t", version: "1" } });
  assert.match(init.msg.result.instructions, /night of sleep belongs to the day they woke up/);
});

test("35 days of history, then a short late night: the brief says easy and shows the numbers against the usual", async () => {
  // Baseline: 7h, asleep 23:30, RHR 60, HRV 50, with small daily wobble so the usual range has width.
  const start = addDays(DAY, -35);
  const p = payload(start, 36, (i, d) => d === DAY
    ? { sleepH: 4.9, bed: "02:51", rhr: 73, hrv: 36 }
    : { sleepH: 7 + ((i % 5) - 2) * 0.1, rhr: 60 + ((i % 3) - 1), hrv: 50 + ((i % 4) - 2), bed: i % 2 ? "23:20" : "23:40", weight: 80 - i * 0.02 });
  const push = await http("POST", "/ingest", { token: ingestTok, raw: body(p) });
  assert.equal(push.status, 200, push.text);
  const r = await call(readTok, "get_brief", { day: DAY });
  assert.equal(r.isError, false, r.text);
  const b = r.data;
  assert.equal(b.verdict.call, "easy");
  assert.deepEqual(b.verdict.worse.sort(), ["HRV", "resting heart rate", "sleep"]);
  assert.equal(b.sleep.asleep, "4h 54m");
  assert.equal(b.sleep.flag, "low");
  assert.equal(b.sleep.reading, "worse");
  assert.equal(b.sleep.fell_asleep, "02:51");
  // 60-day window since S-03: all 35 nights count, 18 at 23:40 and 17 at 23:20, so the median is 23:40 (was 23:30 over 30).
  assert.equal(b.sleep.fell_asleep_vs_usual.usual, "23:40");
  assert.equal(b.sleep.fell_asleep_vs_usual.reading, "worse");
  assert.equal(b.recovery.resting_hr.value, 73);
  assert.equal(b.recovery.resting_hr.usual, 60);
  assert.equal(b.recovery.hrv.reading, "worse");
  // 60-day window since S-03 (was 30): every one of the 35 history days now counts.
  assert.equal(b.recovery.resting_hr.baseline_days, 35);
  assert.match(b.summary, /Slept 4h 54m \(usual 7h 00m\), asleep 02:51 \(usual 23:40\)/);
  assert.match(b.summary, /Call: easy/);
  assert.ok(b.freshness.last_sync);
  assert.equal(b.freshness.latest_day.sleep_h, DAY);
  assert.equal(b.body.weight_kg, 80);
  assert.equal(b.body.logged_today, true);
});

test("sleep and metric series carry the usual from before the range", async () => {
  const s = await call(readTok, "get_sleep", { from: addDays(DAY, -6), to: DAY });
  assert.equal(s.data.nights_with_data, 7);
  assert.equal(s.data.keyed_by, "the day you woke up");
  assert.equal(s.data.nights.at(-1).asleep_flag, "low");
  assert.equal(s.data.nights.at(-1).bedtime_flag, "later than usual");
  const m = await call(readTok, "get_metrics", { metrics: ["resting_hr", "bedtime", "steps"], from: addDays(DAY, -13), to: DAY, every: "week" });
  assert.equal(m.isError, false, m.text);
  const rhr = m.data.series.find((x) => x.metric === "resting_hr");
  assert.equal(rhr.better, "lower");
  assert.equal(rhr.usual_before_range.usual, 60);
  assert.ok(rhr.weeks.length >= 2);
  assert.match(m.data.series.find((x) => x.metric === "bedtime").average, /^\d\d:\d\d$/);
  const bad = await call(readTok, "get_metrics", { metrics: ["mood"], from: DAY, to: DAY });
  assert.equal(bad.isError, true);
  assert.match(bad.text, /Unknown metric mood\. Known: resting_hr/);
});

test("log_sets: names resolve, retries are no-ops, gaps start new sessions, warm-ups don't count", async () => {
  const t = (hm) => `2026-10-06T${hm}:00+05:30`;
  const sets = [
    { id: "s-bench-w", exercise: "bench", kind: "warmup", weight_kg: 40, reps: 10, performed_at: t("19:05") },
    { id: "s-bench-1", exercise: "bench", weight_kg: 60, reps: 8, target_reps: 8, performed_at: t("19:10") },
    { id: "s-bench-2", exercise: "bench press", weight_kg: 60, reps: 8, target_reps: 8, performed_at: t("19:14") },
    { id: "s-bench-3", exercise: "barbell-bench-press-medium-grip", weight_kg: 60, reps: 8, target_reps: 8, performed_at: t("19:18") },
  ];
  const a = await call(writeTok, "log_sets", { sets, title: "Push" });
  assert.equal(a.isError, false, a.text);
  assert.equal(a.data.logged.length, 4);
  assert.deepEqual(a.data.next_sets[0], { exercise: { id: "barbell-bench-press-medium-grip", name: "Barbell Bench Press - Medium Grip" }, working_sets_today: 3,
    today_target: null, next: "No earlier session to set a target from; today's sets become next time's baseline." });
  const again = await call(writeTok, "log_sets", { sets });
  assert.equal(again.data.logged.length, 0);
  assert.equal(again.data.already_logged.length, 4);
  assert.equal(one("SELECT COUNT(*) n FROM sets").n, 4);
  // An hour later: same session. Four hours later: a new one.
  const later = await call(writeTok, "log_sets", { sets: [{ id: "s-ohp-1", exercise: "ohp", weight_kg: 35, reps: 8, performed_at: t("20:10") }] });
  assert.equal(later.data.session.id, a.data.session.id);
  const next = await call(writeTok, "log_sets", { sets: [{ id: "s-row-1", exercise: "barbell row", weight_kg: 50, reps: 10, performed_at: "2026-10-07T07:30:00+05:30" }] });
  assert.notEqual(next.data.session.id, a.data.session.id);

  const w = await call(readTok, "get_workout", { id: a.data.session.id });
  assert.equal(w.data.working_sets, 4);
  assert.equal(w.data.volume_kg, 60 * 8 * 3 + 35 * 8);
  const bench = w.data.exercises.find((e) => e.name === "Barbell Bench Press - Medium Grip");
  assert.equal(bench.e1rm_kg_estimate, 76);
  assert.match(String(w.data.watch), /no Apple Watch workout/);

  const h = await call(readTok, "get_exercise_history", { exercise: "bench" });
  assert.equal(h.data.next.suggestion, "62.5 kg × 8 for 3 sets");
  assert.equal(h.data.records.best_e1rm_kg_estimate, 76);
});

test("an unclear exercise logs nothing and comes back as a tool error with candidates", async () => {
  const before = one("SELECT COUNT(*) n FROM sets").n;
  const r = await call(writeTok, "log_sets", { sets: [{ exercise: "press", weight_kg: 20, reps: 10 }] });
  assert.equal(r.isError, true);
  assert.match(r.text, /Nothing logged\. Use an exercise id for: "press": did you mean/);
  assert.equal(one("SELECT COUNT(*) n FROM sets").n, before);
  const read = await mcp(readTok, "tools/call", { name: "log_sets", arguments: { sets: [{ exercise: "bench", weight_kg: 20, reps: 10 }] } });
  assert.ok(read.msg.error || read.msg.result?.isError, "read tokens don't get write tools");
  assert.equal(one("SELECT COUNT(*) n FROM sets").n, before);
});

test("edits, deletes and the training summary", async () => {
  const e = await call(writeTok, "edit_set", { id: "s-bench-3", reps: 9 });
  assert.equal(e.data.reps, 9);
  const d = await call(writeTok, "edit_set", { id: "s-row-1", delete: true });
  assert.equal(d.data.deleted, true);
  const sum = await call(readTok, "get_training_summary", { from: "2026-10-01", to: "2026-10-07" });
  assert.equal(sum.isError, false, sum.text);
  assert.equal(sum.data.strength_sessions, 1, "a session whose only set was deleted isn't counted");
  assert.equal(sum.data.working_sets_by_muscle.chest, 3);
  assert.equal(sum.data.records.length, 2);
  assert.equal(sum.data.days_since_trained.chest, 1);
  assert.equal(sum.data.days_since_trained.quadriceps, null);
  const list = await call(readTok, "list_workouts", { from: "2026-10-01", to: "2026-10-07" });
  assert.ok(list.data.workouts.length >= 1);
  const f = await call(readTok, "get_freshness");
  assert.ok(f.data.syncs_last_7_days >= 1);
  assert.match(f.data.note, /not zero/);
  assert.ok(all("SELECT tool FROM calls").some((c) => c.tool === "log_sets"));
});

test("app parity: get_today is the GET /v2/today body; get_brief adds scores and plan; verdict.call follows the band", async () => {
  const day = (await http("GET", "/v2/today", { token: readTok })).json.day;
  const [viaHttp, viaMcp] = [await http("GET", "/v2/today", { token: readTok }), await call(readTok, "get_today", {})];
  const strip = (b) => { const { generated_at: _g, pulse, ...rest } = b; return { ...rest, pulse: { ...pulse, now: null } }; };
  assert.deepEqual(strip(viaMcp.data), strip(viaHttp.json));
  assert.equal(viaMcp.data.day, day);
  const b = (await call(readTok, "get_brief", { day: DAY })).data;
  assert.equal(b.scores.recovery.band, "rest"); assert.equal(b.verdict.call, "easy");
  assert.match(b.verdict.rule, /recovery band/);
  assert.ok(b.plan.headline && b.plan.action.kind);
  const s = await call(readTok, "get_scores", { from: addDays(DAY, -2), to: DAY });
  assert.equal(s.data.days.length, 3); assert.equal(s.data.days[2].recovery.band, "rest");
  assert.equal((await call(readTok, "get_scores", { from: "2026-01-01", to: "2026-06-01" })).isError, true);
  const sl = await call(readTok, "get_sleep", { from: DAY, to: DAY });
  assert.equal(typeof sl.data.nights[0].score, "number"); assert.ok("wakeups" in sl.data.nights[0]);
});

test("food and targets over MCP; training summary carries heat, splits and weekly sets", async () => {
  const entry = { id: "mcp-f1", meal_id: "mcp-m1", slot: "lunch", eaten_at: `${DAY}T13:00:00+05:30`, name: "Dal", kcal: 220, protein_g: 12, source: "describe", estimate: true };
  const r = await call(writeTok, "log_food", { entries: [entry] });
  assert.equal(r.isError, false, r.text); assert.equal(r.data.accepted.inserted, 1);
  assert.equal((await call(writeTok, "log_food", { entries: [entry] })).data.accepted.unchanged, 1);
  const f = await call(readTok, "get_food_day", { day: DAY });
  assert.equal(f.data.kcal_eaten, 220);
  const t = await call(readTok, "get_targets");
  assert.ok(t.data.effective.kcal > 0);
  const sum = await call(readTok, "get_training_summary", { from: "2026-10-01", to: "2026-10-07" });
  assert.equal(Object.keys(sum.data.heat).length, 17); assert.ok(Array.isArray(sum.data.splits)); assert.equal(Object.keys(sum.data.weekly_sets.status).length, 17);
});

test("log_sets: next_sets carries today's target from last session and the next set", async () => {
  const t = (d, hm) => `2026-10-${d}T${hm}:00+05:30`;
  const r = await call(writeTok, "log_sets", { sets: [{ id: "ns-1", exercise: "bench", weight_kg: 62.5, reps: 8, performed_at: t("09", "19:10") }] });
  assert.equal(r.isError, false, r.text);
  const n = r.data.next_sets[0];
  assert.equal(n.today_target, "62.5 kg × 8 for 3 sets", "60 kg × 8 × 3 hit last time: add 2.5 kg");
  assert.equal(n.working_sets_today, 1);
  assert.equal(n.next, "Set 2 of 3: 62.5 kg × 8");
});
