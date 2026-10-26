import { test } from "node:test";
import assert from "node:assert/strict";
import { call, http, tokens } from "./_env.mjs";
import { today } from "../dist/src/time.js";

const write = tokens.createToken("parity agent", "write").token;
const read = tokens.createToken("parity reader", "read").token;
const ok = (r) => { assert.ok(!r.isError, r.text); return r.data ?? JSON.parse(r.text); };

test("an agent logs a weigh-in, sees it on Body, and can delete it", async () => {
  const r = ok(await call(write, "log_weight", { kg: 91.4, id: "w-1" }));
  assert.equal(r.entry.kg, 91.4); assert.equal(r.recent[0].id, "w-1");
  assert.equal(ok(await call(write, "log_weight", { kg: 91.4, id: "w-1" })).entry.changed, false, "a retry is a no-op");
  const body = await http("GET", "/v2/body", { token: read });
  assert.equal(body.json.weight.latest.kg, 91.4);
  ok(await call(write, "log_weight", { id: "w-1", delete: true }));
  assert.equal((await http("GET", "/v2/body", { token: read })).json.weight.latest, null);
  assert.ok((await call(write, "log_weight", {})).isError);
});

test("an agent deletes a wrong food by id or by meal", async () => {
  const at = `${today()}T08:00:00+05:30`;
  const e = (id, meal) => ({ id, meal_id: meal, slot: "breakfast", eaten_at: at, name: id, kcal: 100, source: "manual" });
  ok(await call(write, "log_food", { entries: [e("a", "m1"), e("b", "m1"), e("c", "m2")] }));
  const one = ok(await call(write, "delete_food", { id: "c" }));
  assert.equal(one.deleted, 1);
  const meal = ok(await call(write, "delete_food", { meal_id: "m1" }));
  assert.equal(meal.deleted, 2); assert.equal(meal.day.kcal_eaten, 0);
  assert.ok((await call(write, "delete_food", { id: "a", meal_id: "m1" })).isError);
});

test("an agent sets targets and edits splits, and the app reads the same", async () => {
  assert.equal(ok(await call(write, "set_targets", { steps: 9000 })).effective.steps, 9000);
  assert.equal((await http("GET", "/v2/targets", { token: read })).json.effective.steps, 9000);
  ok(await call(write, "edit_split", { name: "Push", muscles: ["chest", "shoulders", "triceps"] }));
  ok(await call(write, "edit_split", { name: "push", muscles: ["chest", "triceps"] }));
  const splits = (await http("GET", "/v2/splits", { token: read })).json.splits;
  assert.deepEqual(splits.map((x) => [x.name, x.muscles]), [["push", ["chest", "triceps"]]]);
  ok(await call(write, "edit_split", { name: "Push", delete: true }));
  assert.deepEqual((await http("GET", "/v2/splits", { token: read })).json.splits, []);
});
