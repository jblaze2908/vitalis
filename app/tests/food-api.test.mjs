import { test } from "node:test";
import assert from "node:assert/strict";
import { http, one, tokens } from "./_env.mjs";
import { foodDay, foodQuick, usualFor } from "../dist/src/food.js";
import { addDays, today } from "../dist/src/time.js";

const write = tokens.createToken("food write", "write").token;
const read = tokens.createToken("food read", "read").token;
const T = today();
const at = (day, hm) => `${day}T${hm}:00+05:30`;
const entry = (id, meal, props = {}) => ({ id, meal_id: meal, slot: "breakfast", eaten_at: at(addDays(T, -1), "08:12"), name: "Masala omelette",
  portion_text: "3 eggs", kcal: 310, protein_g: 21, carbs_g: 6, fat_g: 22, source: "manual", ...props });
const post = (entries, token = write) => http("POST", "/v2/food/entries", { token, json: { entries } });

test("three identical posts make one entry; a changed body updates it; the day comes back in the response", async () => {
  let r;
  for (let i = 0; i < 3; i++) r = await post([entry("E1", "M1")]);
  assert.equal(r.status, 200, r.text);
  assert.deepEqual(r.json.accepted, { inserted: 0, updated: 0, unchanged: 1 });
  assert.equal(one("SELECT COUNT(*) n FROM food_entries").n, 1);
  assert.equal(r.json.day.kcal_eaten, 310); assert.equal(r.json.day.meals[0].time, "08:12"); assert.equal(r.json.day.meals[0].label, "BREAKFAST");
  r = await post([entry("E1", "M1", { kcal: 330 })]);
  assert.deepEqual(r.json.accepted, { inserted: 0, updated: 1, unchanged: 0 });
  assert.equal(r.json.day.kcal_eaten, 330);
});

test("DELETE /v2/food/meals/:meal_id removes every entry of that add; twice is 200 with 0; unknown is 404", async () => {
  await post([entry("E2", "M2", { slot: "lunch", eaten_at: at(addDays(T, -1), "13:05"), name: "Rice", kcal: 200 }), entry("E3", "M2", { slot: "lunch", eaten_at: at(addDays(T, -1), "13:05"), name: "Dal", kcal: 180 })]);
  let r = await http("DELETE", "/v2/food/meals/M2", { token: write });
  assert.equal(r.status, 200); assert.equal(r.json.deleted, 2); assert.equal(r.json.day.meals.some((m) => m.slot === "lunch"), false);
  r = await http("DELETE", "/v2/food/meals/M2", { token: write });
  assert.equal(r.json.deleted, 0);
  assert.equal((await http("DELETE", "/v2/food/meals/nope", { token: write })).status, 404);
  r = await post([entry("E2", "M2", { slot: "lunch", eaten_at: at(addDays(T, -1), "13:05"), name: "Rice", kcal: 200 })]);
  assert.equal(r.json.accepted.unchanged, 1, "a repost of the same body doesn't revive it");
  assert.equal(one("SELECT deleted_at FROM food_entries WHERE id='E2'").deleted_at !== null, true);
  assert.equal((await http("DELETE", "/v2/food/entries/E1", { token: write })).json.deleted, 1);
});

test("the usual appears only after three occurrences within 28 days", async () => {
  const meal = (i, day) => [entry(`U${i}a`, `UM${i}`, { slot: "dinner", eaten_at: at(day, "20:00"), name: "Chicken breast", kcal: 248 }),
    entry(`U${i}b`, `UM${i}`, { slot: "dinner", eaten_at: at(day, "20:00"), name: "Rice", kcal: 390 })];
  await post(meal(1, addDays(T, -30)));
  await post(meal(2, addDays(T, -10)));
  await post(meal(3, addDays(T, -5)));
  assert.equal(usualFor("dinner", T), null, "the one 30 days ago is outside the window");
  await post(meal(4, addDays(T, -2)));
  const u = usualFor("dinner", T);
  assert.equal(u.kcal, 638); assert.equal(u.items.length, 2); assert.equal(u.meal_signature, "chicken breast|rice");
  const q = foodQuick("dinner");
  assert.equal(q.usual.kcal, 638); assert.ok(q.recent.length >= 2); assert.equal(new Set(q.recent.map((r) => r.name.toLowerCase())).size, q.recent.length);
});

test("kcal_left negative sets over; empty day; read scope; validation", async () => {
  await post([entry("BIG", "MB", { eaten_at: at(T, "08:00"), name: "Feast", kcal: 5000 })]);
  const d = foodDay(T);
  assert.equal(d.over, true); assert.ok(d.kcal_left < 0); assert.equal(d.date_label.startsWith("TODAY · "), true); assert.equal(d.next_day, null);
  assert.equal(d.meals[0].just_added, true);
  const empty = foodDay(addDays(T, -40));
  assert.equal(empty.empty, true); assert.deepEqual(empty.meals, []);
  assert.equal((await http("GET", "/v2/food/day", { token: read })).status, 200);
  assert.equal((await post([entry("X", "MX")], read)).status, 403);
  assert.equal((await post([entry("X", "MX", { source: "magic" })])).status, 422);
  assert.equal((await post([])).status, 422);
  assert.equal((await http("GET", "/v2/food/quick?slot=brunch", { token: read })).status, 400);
});

test("saved meals are idempotent by id and appear in quick add until deleted", async () => {
  const body = { id: "S1", name: "Post-gym shake", slot: "snack", items: [{ name: "Whey", portion_text: "1 scoop", grams: 30, kcal: 120, protein_g: 24, carbs_g: 3, fat_g: 1 }] };
  for (let i = 0; i < 2; i++) assert.equal((await http("POST", "/v2/food/saved", { token: write, json: body })).status, 200);
  assert.equal(one("SELECT COUNT(*) n FROM saved_meals").n, 1);
  assert.equal(foodQuick("snack").saved[0].kcal, 120);
  assert.equal((await http("DELETE", "/v2/food/saved/S1", { token: write })).status, 200);
  assert.deepEqual(foodQuick("snack").saved, []);
  assert.equal((await http("DELETE", "/v2/food/saved/nope", { token: write })).status, 404);
});
