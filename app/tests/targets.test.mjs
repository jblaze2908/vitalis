import { test } from "node:test";
import assert from "node:assert/strict";
import { addDays, body, http, ingest, one, payload, tokens } from "./_env.mjs";
import { today } from "../dist/src/time.js";

const read = tokens.createToken("targets read", "read").token;
const write = tokens.createToken("targets write", "write").token;
const ingestTok = tokens.createToken("targets ingest", "ingest").token;

test("an empty install returns computed defaults and nothing set", async () => {
  const r = await http("GET", "/v2/targets", { token: read });
  assert.equal(r.status, 200, r.text);
  assert.equal(r.json.effective.steps, 8000);
  assert.equal(r.json.effective.kcal, 2200);
  assert.equal(r.json.effective.protein_g, 140);
  assert.equal(r.json.effective.sleep_need_h, 8);
  assert.equal(r.json.effective.wake_time, "07:00");
  assert.equal(r.json.effective.bed_by, "23:00");
  assert.equal(Object.values(r.json.values).every((v) => v === null), true);
  assert.equal(Object.values(r.json.is_set).some(Boolean), false);
  assert.ok(r.json.freshness && "data_through" in r.json.freshness);
});

test("30 days at 76.4 kg suggest 2,300 kcal and 155 g protein", async () => {
  const t = today();
  ingest(body(payload(addDays(t, -29), 30, () => ({ weight: 76.4, steps: 8600 }))), { origin: "test" });
  const r = await http("GET", "/v2/targets", { token: read });
  assert.equal(r.json.suggested.kcal.value, 2300);
  assert.equal(r.json.effective.kcal, 2300);
  assert.equal(r.json.suggested.protein_g.value, 155);
  assert.equal(r.json.suggested.steps.value, 8500);
  assert.equal(r.json.suggested.steps.basis, "YOUR USUAL IS 8,600");
  assert.equal(r.json.suggested.goal_weight_kg.basis, "NOW 76.4 KG");
});

test("PUT stores a partial update, null clears a key, and versions move", async () => {
  const v0 = one("SELECT value FROM meta WHERE key='targets_version'").value;
  let r = await http("PUT", "/v2/targets", { token: write, json: { steps: 9000, protein_g: 160, goal_weight_kg: 74.0, kcal_mode: "adaptive", wake_time: "06:30" } });
  assert.equal(r.status, 200, r.text);
  assert.equal(r.json.values.steps, 9000); assert.equal(r.json.effective.steps, 9000);
  assert.equal(r.json.effective.protein_g, 160); assert.equal(r.json.is_set.goal_weight_kg, true);
  assert.equal(r.json.effective.bed_by, "23:30", "need is 7 h from the 30 synthetic 7 h nights");
  assert.ok(one("SELECT value FROM meta WHERE key='targets_version'").value > v0);
  r = await http("PUT", "/v2/targets", { token: write, json: { steps: null } });
  assert.equal(r.json.values.steps, null); assert.equal(r.json.effective.steps, 8500);
  assert.equal(r.json.values.protein_g, 160, "keys not sent stay");
  r = await http("PUT", "/v2/targets", { token: write, json: { kcal_mode: "fixed", kcal: 2500 } });
  assert.equal(r.json.effective.kcal, 2500);
});

test("invalid values are 422 naming the field; scopes are enforced", async () => {
  for (const [json, field] of [[{ steps: 500 }, "steps"], [{ sleep_need_h: 7.3 }, "sleep_need_h"], [{ wake_time: "7am" }, "wake_time"],
    [{ crown_step_kg: 3 }, "crown_step_kg"], [{ colour: "red" }, ""], [{ weekly_sets_min: 30, weekly_sets_max: 20 }, "weekly_sets_min"]]) {
    const r = await http("PUT", "/v2/targets", { token: write, json });
    assert.equal(r.status, 422, JSON.stringify(json)); assert.equal(r.json.code, "invalid");
    if (field) assert.match(r.json.error, new RegExp(`^${field}`));
  }
  assert.equal((await http("PUT", "/v2/targets", { token: read, json: { steps: 9000 } })).status, 403);
  assert.equal((await http("GET", "/v2/targets", { token: ingestTok })).status, 403);
});
