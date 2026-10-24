import { test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { addDays, body, http, ingest, payload, tokens } from "./_env.mjs";
import { sleepDay, sleepWeek } from "../dist/src/sleep-view.js";
import { today } from "../dist/src/time.js";

const read = tokens.createToken("sleep read", "read").token;
const ingestTok = tokens.createToken("sleep ingest", "ingest").token;
const D = "2026-04-10";
ingest(body(payload(addDays(D, -30), 30)), { origin: "test" });

const stage = (value, start, end) => ({ uuid: randomUUID(), type: "HKCategoryTypeIdentifierSleepAnalysis", kind: "category", value, start, end,
  value_label: ["inBed", "asleepUnspecified", "awake", "asleepCore", "asleepDeep", "asleepREM"][value],
  source: { name: "Native Watch", bundle_id: "com.apple.health", version: "1", os_version: "26" } });

test("a native night with no in-bed samples takes efficiency from sleep start and end", async () => {
  const r = await http("POST", "/v2/samples", { token: ingestTok, json: { schema: 1, batch_id: randomUUID(), client: { install_id: "t", app_version: "0", os: "iOS", model: "T" },
    upserts: [stage(3, `${addDays(D, -1)}T23:00:00.000+05:30`, `${D}T03:00:00.000+05:30`), stage(2, `${D}T03:00:00.000+05:30`, `${D}T03:20:00.000+05:30`),
      stage(4, `${D}T03:20:00.000+05:30`, `${D}T06:30:00.000+05:30`)], deletions: [], daily_stats: [] } });
  assert.equal(r.status, 200, r.text);
  const s = sleepDay(D, Date.parse(`${addDays(D, 1)}T12:00:00+05:30`));
  assert.equal(s.has_night, true);
  const eff = s.parts.find((p) => p.key === "efficiency");
  assert.equal(eff.detail, "96% ASLEEP"); assert.equal(eff.score, 100);
  assert.equal(s.parts.find((p) => p.key === "wakeups").detail.startsWith("1"), true);
  assert.equal(s.night.source, "Native Watch");
  assert.equal(s.stages.note, "Stages are estimates and are not part of the score.");
  assert.deepEqual(s.parts.map((p) => p.weight), [0.4, 0.2, 0.2, 0.2]);
  assert.equal(s.duration.need_basis, "history");
  assert.equal(s.next_day, addDays(D, 1));
});

test("a missing night has no score or parts but still says when to go to bed", () => {
  const s = sleepDay("2025-12-01", Date.parse("2025-12-01T12:00:00+05:30"));
  assert.equal(s.has_night, false);
  assert.equal(s.score, null); assert.equal(s.parts, null); assert.equal(s.night, null); assert.equal(s.stages, null);
  assert.equal(s.tonight.bed_by, "23:00"); assert.equal(s.tonight.label, "8H BEFORE YOUR 07:00 WAKE");
  assert.equal(s.next_day, null, "the date is today at that time");
});

test("week: seven nights oldest first, average score and bedtime spread", async () => {
  const w = sleepWeek(addDays(D, -1), Date.parse(`${D}T12:00:00+05:30`));
  assert.equal(w.nights.length, 7); assert.equal(w.nights[0].day, addDays(D, -7));
  assert.ok(w.nights.every((n) => n.score !== null));
  assert.equal(w.bedtime_spread_min, 0);
  assert.match(w.label, /^AVG \d+ · BED ± 0M$/);
  const r = await http("GET", `/v2/sleep/week?end=${addDays(D, -1)}`, { token: read });
  assert.equal(r.status, 200); assert.equal(r.json.nights.length, 7);
  const t = await http("GET", "/v2/sleep", { token: read });
  assert.equal(t.json.day, today()); assert.equal(t.json.next_day, null);
});
