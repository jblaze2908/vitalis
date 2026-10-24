import { beforeEach, test } from "node:test";
import assert from "node:assert/strict";
import "./_env.mjs";
import { run } from "../dist/src/db.js";
import { barcode, barcodePutSchema, putBarcode, resetOff, searchFood, setClock, setFetch, userAgent } from "../dist/src/off.js";

const DAY = 86_400_000;
let t, calls, handler;
const resp = (status, body) => ({ ok: status >= 200 && status < 300, status, json: async () => body });
const hit = (code, name, kcal, extra = {}) => ({ code, product_name: name, brands: ["Amul"], nutriments: kcal == null ? {} : { "energy-kcal_100g": kcal, proteins_100g: 20, carbohydrates_100g: 4.5, fat_100g: 25 }, ...extra });
const searchOk = (hits, page_count = 1) => resp(200, { hits, count: hits.length, page: 1, page_size: 20, page_count });

beforeEach(() => {
  resetOff();
  t = Date.UTC(2026, 9, 24, 8);
  setClock(() => t);
  calls = [];
  handler = () => searchOk([hit("8901234567890", "Malai Paneer", 314)]);
  setFetch(async (url, init) => { calls.push({ url, init }); return handler(url); });
});

let n = 0;
function entry(name, { deleted = false, kcal = 310, portion = "3 eggs", estimate = 0, at = Date.UTC(2026, 9, 23, 3) } = {}) {
  const id = `E${++n}`;
  run(`INSERT INTO food_entries (id, meal_id, day, slot, eaten_at, tz_offset_min, name, portion_text, grams, kcal, protein_g, carbs_g, fat_g, source, estimate, created_at, updated_at, deleted_at)
       VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`, id, `M${n}`, "2026-10-23", "breakfast", at, 330, name, portion, 150, kcal, 21, 6, 22, "manual", estimate, at, at, deleted ? at : null);
}

async function rejects(p, status) {
  await assert.rejects(p, (e) => e.status === status && (status !== 400 || e.code === "bad_request"));
}

test("a cached query makes no second fetch within 7 days, and fetches again after", async () => {
  const a = await searchFood("  Malai   PANEER ", 1);
  assert.equal(a.q, "malai paneer");
  assert.equal(a.remote, "ok");
  assert.equal(calls.length, 1);
  assert.match(calls[0].url, /^https:\/\/search\.openfoodfacts\.org\/search\?q=malai%20paneer&page=1&page_size=20&fields=code,product_name,brands,serving_size,serving_quantity,nutriments$/);
  assert.ok(calls[0].init.signal instanceof AbortSignal);
  t += 7 * DAY - 1;
  const b = await searchFood("malai paneer", 1);
  assert.equal(calls.length, 1);
  assert.deepEqual(b.results, a.results);
  t += 2;
  await searchFood("malai paneer", 1);
  assert.equal(calls.length, 2);
});

test("hits without kcal are dropped; serving_quantity grams are used, else 100 g", async () => {
  handler = () => searchOk([
    hit("1111111111111", "No Kcal Paneer", null),
    hit("2222222222222", "Paneer Cubes", 314, { serving_size: "40 g", serving_quantity: 40 }),
    hit("3333333333333", "Paneer, Fresh", 265, { brands: "Gowardhan, Parag" }),
  ], 3);
  const r = await searchFood("paneer cube test", 1);
  assert.equal(r.count, 2);
  assert.equal(r.next_page, 2);
  const [cubes, fresh] = r.results;
  assert.deepEqual(cubes, { key: "off:2222222222222", name: "Paneer Cubes", brand: "Amul", source: "search", source_ref: "2222222222222", estimate: false,
    per_100g: { kcal: 314, protein_g: 20, carbs_g: 4.5, fat_g: 25 },
    serving: { label: "40 G", grams: 40, kcal: 126, protein_g: 8, carbs_g: 1.8, fat_g: 10 }, label: "40 G · OPEN FOOD FACTS" });
  assert.equal(fresh.brand, "Gowardhan");
  assert.deepEqual(fresh.serving, { label: "100 G", grams: 100, kcal: 265, protein_g: 20, carbs_g: 4.5, fat_g: 25 });
  assert.equal(fresh.label, "100 G · OPEN FOOD FACTS");
});

test("the 9th search in a minute returns local results with remote rate_limited and no fetch; the bucket refills", async () => {
  entry("Masala omelette");
  entry("Masala omelette", { kcal: 999, at: Date.UTC(2026, 9, 20, 3) }); // older duplicate name
  entry("Omelette deleted", { deleted: true });
  run("INSERT INTO saved_meals (id, name, slot, items_json, created_at, updated_at) VALUES (?,?,?,?,?,?)", "S1", "Omelette plate", "breakfast",
    JSON.stringify([{ name: "Egg", grams: 100, kcal: 150, protein_g: 12, carbs_g: 1, fat_g: 10 }, { name: "Toast", grams: 30, kcal: 80, protein_g: 3, carbs_g: 15, fat_g: 1 }]), t, t);
  for (let i = 0; i < 8; i++) assert.equal((await searchFood(`rate ${i}`, 1)).remote, "ok");
  assert.equal(calls.length, 8);
  const r = await searchFood("omelette", 1);
  assert.equal(r.remote, "rate_limited");
  assert.equal(calls.length, 8);
  assert.equal(r.next_page, null);
  assert.deepEqual(r.results.map((x) => [x.key, x.source]), [["recent:Masala omelette", "recent"], ["saved:S1", "saved"]]);
  assert.equal(r.results[0].serving.kcal, 310);
  assert.equal(r.results[0].label, "3 EGGS · RECENT");
  assert.deepEqual(r.results[1].serving, { label: "2 ITEMS", grams: 130, kcal: 230, protein_g: 15, carbs_g: 16, fat_g: 11 });
  assert.equal(r.count, 2);
  t += 7_500; // one token at 8/min
  assert.equal((await searchFood("omelette", 1)).remote, "ok");
  assert.equal(calls.length, 9);
});

test("an OFF error or timeout returns local results with remote unavailable (HTTP 200 body, nothing cached)", async () => {
  entry("Dal tadka", { portion: "1 bowl, 250 g", estimate: 1 });
  handler = () => { throw Object.assign(new Error("timed out"), { name: "TimeoutError" }); };
  const a = await searchFood("dal", 1);
  assert.equal(a.remote, "unavailable");
  assert.deepEqual(a.results.map((x) => x.label), ["1 BOWL, 250 G · ESTIMATE"]);
  handler = () => resp(500, {});
  assert.equal((await searchFood("dal", 1)).remote, "unavailable");
  assert.equal(calls.length, 2);
  handler = () => searchOk([]);
  assert.equal((await searchFood("dal", 1)).remote, "ok");
});

test("q shorter than 2 characters and a bad page are 400", async () => {
  await rejects(searchFood("a", 1), 400);
  await rejects(searchFood("   b   ", 1), 400);
  await rejects(searchFood("ok", 0), 400);
  await rejects(searchFood("ok", 1.5), 400);
  assert.equal(calls.length, 0);
});

test("barcode status 0 is found:false, cached for a day, then refetched", async () => {
  handler = () => resp(404, { status: 0, status_verbose: "product not found" });
  const miss = { code: "8904109450018", found: false, source: "openfoodfacts", item: null, label: "NOT IN OPEN FOOD FACTS YET" };
  assert.deepEqual(await barcode("8904109450018"), miss);
  assert.equal(calls[0].url, "https://world.openfoodfacts.org/api/v2/product/8904109450018?fields=code,product_name,brands,serving_size,serving_quantity,quantity,nutriments");
  t += DAY - 1;
  assert.deepEqual(await barcode("8904109450018"), miss);
  assert.equal(calls.length, 1);
  t += 2;
  await barcode("8904109450018");
  assert.equal(calls.length, 2);
});

test("a found barcode is cached for 30 days; found without kcal counts as not found", async () => {
  handler = (url) => url.includes("/12345678?") ? resp(200, { status: 1, product: { code: "12345678", product_name: "Mystery", nutriments: {} } })
    : resp(200, { status: 1, product: { code: "8901063010031", product_name: "Lassi", brands: "Amul", quantity: "200 ml bottle", serving_size: "200 ml bottle", serving_quantity: "200",
      nutriments: { "energy-kcal_100g": 72, proteins_100g: 3, carbohydrates_100g: 11, fat_100g: 2 } } });
  const want = { code: "8901063010031", found: true, source: "openfoodfacts",
    item: { name: "Lassi", brand: "Amul", quantity_label: "200 ML BOTTLE", per_100g: { kcal: 72, protein_g: 3, carbs_g: 11, fat_g: 2 },
      serving: { label: "200 ML BOTTLE", grams: 200, kcal: 144, protein_g: 6, carbs_g: 22, fat_g: 4 } },
    label: "200 ML BOTTLE · OPEN FOOD FACTS" };
  assert.deepEqual(await barcode("8901063010031"), want);
  t += 30 * DAY - 1;
  assert.deepEqual(await barcode("8901063010031"), want);
  assert.equal(calls.length, 1);
  t += 2;
  await barcode("8901063010031");
  assert.equal(calls.length, 2);
  assert.equal((await barcode("12345678")).found, false);
});

test("a user barcode wins over OFF and never refetches", async () => {
  handler = () => resp(200, { status: 1, product: { product_name: "OFF Bar", nutriments: { "energy-kcal_100g": 400 } } });
  assert.equal((await barcode("89041094500181")).source, "openfoodfacts");
  const put = barcodePutSchema.parse({ item: { name: "Protein bar", serving: { label: "1 bar", grams: 40, kcal: 190, protein_g: 10, carbs_g: 20, fat_g: 7 } } });
  const body = putBarcode("89041094500181", put.item);
  assert.deepEqual(body, { code: "89041094500181", found: true, source: "you",
    item: { name: "Protein bar", brand: null, quantity_label: null, per_100g: { kcal: 475, protein_g: 25, carbs_g: 50, fat_g: 17.5 },
      serving: { label: "1 BAR", grams: 40, kcal: 190, protein_g: 10, carbs_g: 20, fat_g: 7 } }, label: "1 BAR · YOURS" });
  t += 365 * DAY;
  assert.deepEqual(await barcode("89041094500181"), body);
  assert.equal(calls.length, 1);
  assert.equal(barcodePutSchema.safeParse({ item: { name: "", serving: { label: "x", kcal: -1 } } }).success, false);
});

test("invalid barcode is 400; OFF down with no cache is 503, with a stale row returns it; empty product bucket is 429", async () => {
  for (const c of ["1234567", "123456789012345", "abcdefgh", "12345678 "]) await rejects(barcode(c), 400);
  assert.throws(() => putBarcode("12ab", { name: "x", serving: { label: "1", kcal: 1 } }), (e) => e.status === 400);
  assert.equal(calls.length, 0);

  handler = () => resp(502, {});
  await rejects(barcode("40000001"), 503);
  handler = () => resp(404, { status: 0 });
  await barcode("40000001");
  t += 2 * DAY;
  handler = () => { throw new TypeError("fetch failed"); };
  assert.equal((await barcode("40000001")).found, false); // stale miss beats an error

  resetOff(); setClock(() => t); setFetch(async (url) => { calls.push({ url }); return resp(404, { status: 0 }); });
  const before = calls.length;
  for (let i = 0; i < 12; i++) await barcode(String(70000000 + i));
  assert.equal(calls.length - before, 12);
  await rejects(barcode("6000000000"), 429);
  assert.equal(calls.length - before, 12);
});

test("User-Agent carries the contact e-mail when set, else the self-hosted fallback with one warning", async () => {
  const saved = process.env.VITALIS_CONTACT_EMAIL;
  const warn = console.warn, warnings = [];
  console.warn = (...a) => warnings.push(a.join(" "));
  try {
    process.env.VITALIS_CONTACT_EMAIL = "contact@example.com";
    await searchFood("ua test one", 1);
    assert.match(calls[0].init.headers["User-Agent"], /^Vitalis\/\d+\.\d+\.\d+ \(contact@example\.com\)$/);
    delete process.env.VITALIS_CONTACT_EMAIL;
    await searchFood("ua test two", 1);
    assert.match(calls[1].init.headers["User-Agent"], /^Vitalis\/\d+\.\d+\.\d+ \(self-hosted\)$/);
    userAgent();
    assert.equal(warnings.length, 1);
    assert.ok(!warnings[0].includes("@"));
  } finally {
    console.warn = warn;
    if (saved === undefined) delete process.env.VITALIS_CONTACT_EMAIL; else process.env.VITALIS_CONTACT_EMAIL = saved;
  }
});
