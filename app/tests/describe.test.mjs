import { test } from "node:test";
import assert from "node:assert/strict";
import { one } from "./_env.mjs";
import { describe as describeMeal, describeMode, DescribeRequest, FixtureParser, resetDescribeLimits, DESCRIBE_NOTE } from "../dist/src/describe.js";

const lunch = (text) => ({ text, slot: "lunch" });
const status = (code, status) => (e) => { assert.equal(e.status, status, e.message); assert.equal(e.code, code); return true; };
const sums = (items, k) => items.reduce((a, it) => a + (it[k] ?? 0), 0);
const item = (over = {}) => ({ name: "Thing", portion_text: "1 serving", grams: 100, kcal: 200, protein_g: 5, carbs_g: 20, fat_g: 8, confidence: "medium",
  portion_options: [{ label: "1 serving", factor: 1 }], ...over });
const fixed = (out) => ({ parse: async () => out });

test("off (the default) and unknown values are 503 unavailable", async () => {
  delete process.env.VITALIS_DESCRIBE;
  assert.equal(describeMode(), "off");
  await assert.rejects(describeMeal(lunch("2 rotis"), "t-off"), status("unavailable", 503));
  process.env.VITALIS_DESCRIBE = "gpt";
  assert.equal(describeMode(), "off");
  await assert.rejects(describeMeal(lunch("2 rotis"), "t-off"), (e) => e.status === 503 && e.message === "Describe isn't set up on this server");
});

test("anthropic mode is the unconfigured provider stub: 503 unavailable", async () => {
  process.env.VITALIS_DESCRIBE = "anthropic";
  await assert.rejects(describeMeal(lunch("2 rotis"), "t-anth"), status("unavailable", 503));
});

test("fixture: paneer tikka, 2 rotis and a bowl of dal → 3 items, roti ×2, totals are the item sums", async () => {
  process.env.VITALIS_DESCRIBE = "fixture";
  const r = await describeMeal(lunch("paneer tikka, 2 rotis and a bowl of dal"), "t-fix");
  assert.equal(r.estimate, true);
  assert.equal(r.note, DESCRIBE_NOTE);
  assert.deepEqual(r.items.map((i) => i.name), ["Paneer tikka", "Roti", "Dal"]);
  const [paneer, roti, dal] = r.items;
  assert.deepEqual(roti, { name: "Roti", portion_text: "2 rotis", grams: 80, kcal: 240, protein_g: 7, carbs_g: 44, fat_g: 4, confidence: "high",
    portion_options: [{ label: "1 roti", factor: 0.5 }, { label: "2 rotis", factor: 1 }, { label: "3 rotis", factor: 1.5 }] });
  assert.equal(paneer.portion_text, "1 plate");
  assert.deepEqual(paneer.portion_options.map((o) => o.label), ["½ plate", "1 plate", "1½ plates"]);
  assert.equal(dal.portion_text, "1 bowl");
  for (const k of ["kcal", "protein_g", "carbs_g", "fat_g"]) assert.equal(r.total[k], sums(r.items, k), k);
  assert.equal(r.total.kcal, 420 + 240 + 170);
});

test("fixture splits on , ; & + and/with, and reads word and fractional quantities", async () => {
  process.env.VITALIS_DESCRIBE = "fixture";
  const r = await describeMeal(lunch("Half a plate of poha; 3 idlis & 2 eggs + tea with 1/2 glass of milk, and an apple"), "t-split");
  assert.deepEqual(r.items.map((i) => [i.name, i.portion_text]),
    [["Poha", "½ plate"], ["Idli", "3 idlis"], ["Egg", "2 eggs"], ["Tea", "1 cup"], ["Milk", "½ glass"], ["Apple", "1 apple"]]);
  assert.equal(r.items[0].kcal, 125);
  assert.deepEqual(r.items[0].portion_options.map((o) => o.label), ["¼ plate", "½ plate", "¾ plate"]);
  assert.deepEqual(r.items[1].portion_options.map((o) => o.label), ["1½ idlis", "3 idlis", "4½ idlis"]);
  assert.deepEqual((await new FixtureParser().parse("sandwich")).map((i) => i.name), ["Sandwich"], "'with' only splits as a whole word");
});

test("unknown dish → 300 kcal, low confidence, null grams and macros, title-cased name", async () => {
  process.env.VITALIS_DESCRIBE = "fixture";
  const r = await describeMeal(lunch("a bowl of mystery stew"), "t-unknown");
  assert.deepEqual(r.items, [{ name: "Mystery Stew", portion_text: "1 serving", grams: null, kcal: 300, protein_g: null, carbs_g: null, fat_g: null,
    confidence: "low", portion_options: [{ label: "½ serving", factor: 0.5 }, { label: "1 serving", factor: 1 }, { label: "1½ servings", factor: 1.5 }] }]);
  assert.deepEqual(r.total, { kcal: 300, protein_g: 0, carbs_g: 0, fat_g: 0 });
});

test("31st call in a rolling hour from one token is 429; another token is fine; after the hour it is fine again", async () => {
  process.env.VITALIS_DESCRIBE = "fixture";
  resetDescribeLimits();
  const t0 = Date.UTC(2026, 9, 24, 8);
  for (let i = 0; i < 30; i++) await describeMeal(lunch("2 rotis"), "t-rate", undefined, { now: t0 + i * 1000 });
  await assert.rejects(describeMeal(lunch("2 rotis"), "t-rate", undefined, { now: t0 + 60_000 }), (e) => {
    assert.equal(e.status, 429); assert.equal(e.code, "rate_limited"); assert.ok(e.extra.retry_after_s > 0); return true;
  });
  await describeMeal(lunch("2 rotis"), "t-rate-other", undefined, { now: t0 + 60_000 });
  // The first call ages out exactly one hour after it was made.
  await describeMeal(lunch("2 rotis"), "t-rate", undefined, { now: t0 + 3_600_000 + 1 });
  await assert.rejects(describeMeal(lunch("2 rotis"), "t-rate", undefined, { now: t0 + 3_600_000 + 2 }), status("rate_limited", 429));
});

test("invalid parser output is 502 describe_failed; so is a parser that throws", async () => {
  process.env.VITALIS_DESCRIBE = "fixture";
  const bad = [
    [item({ kcal: 6000 })],
    Array.from({ length: 13 }, () => item()),
    [{ ...item(), confidence: undefined }],
    [item({ portion_options: [] })],
    { items: [item()] },
  ];
  for (const out of bad) await assert.rejects(describeMeal(lunch("anything"), "t-bad", fixed(out)), status("describe_failed", 502));
  const err = console.error; console.error = () => {};
  try { await assert.rejects(describeMeal(lunch("anything"), "t-bad", { parse: async () => { throw new Error("upstream 500"); } }), status("describe_failed", 502)); }
  finally { console.error = err; }
});

test("provider decimals are rounded and totals still equal the item sums", async () => {
  process.env.VITALIS_DESCRIBE = "fixture";
  const r = await describeMeal(lunch("anything"), "t-round", fixed([item({ kcal: 100.4, protein_g: 2.5, fat_g: null }), item({ kcal: 100.4, protein_g: 2.5 })]));
  assert.deepEqual(r.items.map((i) => i.kcal), [100, 100]);
  for (const k of ["kcal", "protein_g", "carbs_g", "fat_g"]) assert.equal(r.total[k], sums(r.items, k), k);
});

test("a slow parser is 504 describe_timeout and its signal is aborted", async () => {
  process.env.VITALIS_DESCRIBE = "fixture";
  let signal;
  const slow = { parse: (_t, _s, sig) => { signal = sig; return new Promise(() => {}); } };
  await assert.rejects(describeMeal(lunch("anything"), "t-slow", slow, { timeoutMs: 20 }), status("describe_timeout", 504));
  assert.equal(signal.aborted, true);
});

test("request schema: text 3–500 chars and a known slot; describe() rejects a bad body with 422", async () => {
  process.env.VITALIS_DESCRIBE = "fixture";
  assert.equal(DescribeRequest.safeParse({ text: "dal", slot: "dinner" }).success, true);
  for (const bad of [{ text: "hi", slot: "lunch" }, { text: "x".repeat(501), slot: "lunch" }, { text: "2 rotis", slot: "brunch" }, { text: "2 rotis" }])
    assert.equal(DescribeRequest.safeParse(bad).success, false, JSON.stringify(bad).slice(0, 40));
  await assert.rejects(describeMeal({ text: "2 rotis", slot: "brunch" }, "t-schema"), status("invalid", 422));
});

test("describe writes nothing to the database", async () => {
  process.env.VITALIS_DESCRIBE = "fixture";
  const count = (t) => one(`SELECT COUNT(*) n FROM ${t}`).n;
  const before = { food: count("food_entries"), calls: count("calls"), changes: one("SELECT total_changes() n").n };
  await describeMeal(lunch("paneer tikka, 2 rotis and a bowl of dal"), "t-db");
  await assert.rejects(describeMeal(lunch("anything"), "t-db", fixed([item({ kcal: -1 })])), status("describe_failed", 502));
  assert.deepEqual({ food: count("food_entries"), calls: count("calls"), changes: one("SELECT total_changes() n").n }, before);
});

test("POST /v2/food/describe: write scope, off by default, fixture through HTTP", async () => {
  const { http, tokens } = await import("./_env.mjs");
  const w = tokens.createToken("describe http", "write").token, r = tokens.createToken("describe read", "read").token;
  const prev = process.env.VITALIS_DESCRIBE;
  try {
    delete process.env.VITALIS_DESCRIBE;
    let res = await http("POST", "/v2/food/describe", { token: w, json: { text: "2 rotis and dal", slot: "lunch" } });
    assert.equal(res.status, 503); assert.equal(res.json.code, "unavailable");
    process.env.VITALIS_DESCRIBE = "fixture";
    assert.equal((await http("POST", "/v2/food/describe", { token: r, json: { text: "2 rotis", slot: "lunch" } })).status, 403);
    res = await http("POST", "/v2/food/describe", { token: w, json: { text: "2 rotis and dal", slot: "lunch" } });
    assert.equal(res.status, 200, res.text); assert.equal(res.json.estimate, true); assert.equal(res.json.items.length, 2);
  } finally { if (prev === undefined) delete process.env.VITALIS_DESCRIBE; else process.env.VITALIS_DESCRIBE = prev; }
});
