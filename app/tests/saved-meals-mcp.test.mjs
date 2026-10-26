import { test } from "node:test";
import assert from "node:assert/strict";
import { call, http, tokens } from "./_env.mjs";

const write = tokens.createToken("saved agent", "write").token;
const read = tokens.createToken("saved reader", "read").token;
const parse = (r) => { assert.ok(!r.isError, JSON.stringify(r)); return r.data ?? JSON.parse(r.text); };

test("an agent saves a shake once, logs it by name, and the app sees the same saved meal", async () => {
  const saved = parse(await call(write, "save_meal", { name: "Protein shake", portion_text: "1 scoop + 300 ml milk", kcal: 310, protein_g: 40, carbs_g: 18, fat_g: 8 }));
  assert.equal(saved.saved.name, "Protein shake"); assert.equal(saved.saved.kcal, 310);
  // Saving the same name again replaces it rather than adding a second one.
  parse(await call(write, "save_meal", { name: "protein shake", kcal: 320, protein_g: 42 }));
  const quick = await http("GET", "/v2/food/quick", { token: read });
  assert.deepEqual(quick.json.saved.map((m) => [m.name, m.kcal]), [["protein shake", 320]]);

  const day = parse(await call(read, "get_food_day", {}));
  assert.deepEqual(day.saved_meals.map((m) => m.name), ["protein shake"]);

  const logged = parse(await call(write, "log_saved_meal", { meal: "Shake", servings: 2, meal_id: "m-1", slot: "breakfast" }));
  assert.equal(logged.accepted.inserted, 1);
  const again = parse(await call(write, "log_saved_meal", { meal: "Shake", servings: 2, meal_id: "m-1", slot: "breakfast" }));
  assert.equal(again.accepted.inserted, 0, "same meal_id twice logs once");
  const entry = logged.day.meals.flatMap((m) => m.entries ?? m.items ?? []).find((e) => e.name === "protein shake");
  assert.ok(entry, JSON.stringify(logged.day.meals));
  assert.equal(entry.kcal, 640); assert.equal(entry.protein_g, 84); assert.equal(entry.source, "saved");

  assert.ok((await call(write, "log_saved_meal", { meal: "pizza" })).isError);
  parse(await call(write, "save_meal", { name: "protein shake", delete: true }));
  assert.deepEqual((await http("GET", "/v2/food/quick", { token: read })).json.saved, []);
});
