import { test } from "node:test";
import assert from "node:assert/strict";
import { app, call, mcp, tokens } from "./_env.mjs";
import { addDays, today } from "../dist/src/time.js";

const write = tokens.createToken("parity audit", "write").token;
const read = tokens.createToken("parity audit read", "read").token;

/**
 * Every app route and the MCP tool that does the same thing. A new route fails this test until it has a tool,
 * or a stated reason it can't (null + why).
 */
const PARITY = {
  "GET /v2/today": "get_today", "GET /v2/digest": "get_digest", "GET /v2/sleep": "get_sleep_view", "GET /v2/sleep/week": "get_sleep_view",
  "GET /v2/sleep/month": "get_sleep_view", "GET /v2/body": "get_body", "GET /v2/heart": "get_heart_day", "GET /v2/metrics": "get_health_overview",
  "GET /v2/metrics/:key": "get_metrics", "GET /v2/training": "get_training_summary", "GET /v2/training/sessions": "list_workouts",
  "GET /v2/training/sessions/:id": "get_workout", "GET /v2/training/exercises": "list_trained_exercises", "GET /v2/exercises": "find_exercises",
  "GET /v2/exercises/:id": "get_exercise_history", "GET /v2/splits": "get_training_summary", "GET /v2/targets": "get_targets",
  "GET /v2/sync/status": "get_freshness", "GET /v2/food/day": "get_food_day", "GET /v2/food/quick": "get_food_suggestions",
  "GET /v2/food/search": "search_food", "GET /v2/food/barcode/:code": "lookup_barcode",
  "PUT /v2/targets": "set_targets", "POST /v2/weight": "log_weight", "DELETE /v2/weight/:id": "log_weight", "PUT /v2/splits/:id": "edit_split",
  "DELETE /v2/splits/:id": "edit_split", "POST /v2/exercises": "create_exercise", "POST /v2/workouts": "log_sets",
  "POST /v2/food/entries": "log_food", "DELETE /v2/food/entries/:id": "delete_food", "DELETE /v2/food/meals/:meal_id": "delete_food",
  "POST /v2/food/saved": "save_meal", "DELETE /v2/food/saved/:id": "save_meal", "PUT /v2/food/barcode/:code": "save_barcode",
  // Not agent actions: the agent is the describer (the app's server-side Describe is its stand-in), and the rest is plumbing.
  "POST /v2/food/describe": null, "POST /v2/samples": null, "POST /ingest": null, "GET /health": null, "ALL /mcp": null,
};

test("every app route has an MCP tool (or a stated reason it can't)", async () => {
  const routes = [...new Set(app.routes.map((r) => `${r.method} ${r.path}`))];
  assert.deepEqual(routes.filter((r) => !(r in PARITY)), [], "new route without a tool: add the tool and a PARITY line");
  const tools = new Set((await mcp(write, "tools/list")).msg.result.tools.map((t) => t.name));
  assert.deepEqual(Object.values(PARITY).filter((t) => t && !tools.has(t)), []);
  const readTools = new Set((await mcp(read, "tools/list")).msg.result.tools.map((t) => t.name));
  for (const [route, tool] of Object.entries(PARITY)) if (tool && route.startsWith("GET")) assert.ok(readTools.has(tool), `${tool} needs only read scope`);
});

test("the new read tools answer on an empty server", async () => {
  for (const [tool, args] of [["get_digest", {}], ["get_sleep_view", {}], ["get_sleep_view", { week_end: today() }], ["get_sleep_view", { month: today().slice(0, 7) }],
    ["get_body", {}], ["get_heart_day", { day: addDays(today(), -1) }], ["get_health_overview", {}], ["list_trained_exercises", {}], ["get_food_suggestions", { slot: "lunch" }]]) {
    const r = await call(read, tool, args);
    assert.ok(!r.isError, `${tool}: ${r.text}`);
  }
  assert.ok((await call(read, "get_sleep_view", { day: today(), month: "2026-10" })).isError);
});

test("an agent teaches a barcode and finds it again without reaching Open Food Facts", async () => {
  const saved = await call(write, "save_barcode", { code: "8901234567890", item: { name: "Oats", serving: { label: "40 G", grams: 40, kcal: 150, protein_g: 5 } } });
  assert.ok(!saved.isError, saved.text);
  const found = await call(read, "lookup_barcode", { code: "8901234567890" });
  assert.ok(!found.isError, found.text);
  assert.equal(found.data.found, true); assert.equal(found.data.item.name, "Oats");
});
