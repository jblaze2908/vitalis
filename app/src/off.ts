// Open Food Facts proxy: food search (Search-a-licious) and barcode lookup, with caches, token buckets and local-first results.
import { readFileSync } from "node:fs";
import { z } from "zod";
import { all, one, run, tx } from "./db.js";
import { ApiError } from "./http.js";

export type FetchFn = (url: string, init: { headers: Record<string, string>; signal: AbortSignal }) =>
  Promise<{ ok: boolean; status: number; json(): Promise<unknown> }>;

export type Macros = { kcal: number; protein_g: number | null; carbs_g: number | null; fat_g: number | null };
export type Serving = Macros & { label: string; grams: number | null };
export type SearchItem = {
  key: string; name: string; brand: string | null; source: "search" | "recent" | "saved"; source_ref: string | null;
  estimate: boolean; per_100g: Macros | null; serving: Serving; label: string;
};
export type SearchBody = {
  q: string; page: number; remote: "ok" | "rate_limited" | "unavailable"; count: number; results: SearchItem[]; next_page: number | null;
};
export type BarcodeItem = { name: string; brand: string | null; quantity_label: string | null; per_100g: Macros | null; serving: Serving };
export type BarcodeBody = { code: string; found: boolean; source: "openfoodfacts" | "you"; item: BarcodeItem | null; label: string };

const VERSION = (JSON.parse(readFileSync(new URL("../../package.json", import.meta.url), "utf8")) as { version: string }).version;
const DAY_MS = 86_400_000;
const SEARCH_TTL = 7 * DAY_MS, FOUND_TTL = 30 * DAY_MS, MISSING_TTL = DAY_MS;
const MAX_PAGE = 100, MAX_Q = 100, LOCAL_MAX = 5, TIMEOUT_MS = 5000;
const NOT_FOUND_LABEL = "NOT IN OPEN FOOD FACTS YET";
const SEARCH_FIELDS = "code,product_name,brands,serving_size,serving_quantity,nutriments";
const PRODUCT_FIELDS = "code,product_name,brands,serving_size,serving_quantity,quantity,nutriments";

// Continuous refill (cap per 60 s), process-wide: OFF limits are per IP (10 search, 15 product/min); we stay under both.
type Bucket = { cap: number; tokens: number; at: number | null };
const bucket = (cap: number): Bucket => ({ cap, tokens: cap, at: null });
let searchBucket = bucket(8), productBucket = bucket(12);
let fetchImpl: FetchFn = globalThis.fetch as unknown as FetchFn;
let clock: () => number = Date.now;
let warned = false;

export const setFetch = (fn: FetchFn) => { fetchImpl = fn; };
export const setClock = (fn: () => number) => { clock = fn; };
export function resetOff() {
  fetchImpl = globalThis.fetch as unknown as FetchFn;
  clock = Date.now;
  searchBucket = bucket(8); productBucket = bucket(12);
  warned = false;
}

function take(b: Bucket, now: number) {
  if (b.at !== null) b.tokens = Math.min(b.cap, b.tokens + (Math.max(0, now - b.at) * b.cap) / 60_000);
  b.at = now;
  if (b.tokens < 1) return false;
  b.tokens -= 1;
  return true;
}

/** OFF requires `AppName/Version (ContactEmail)`; read per call so a changed env applies without restart. */
export function userAgent() {
  const email = process.env.VITALIS_CONTACT_EMAIL?.trim();
  if (email) return `Vitalis/${VERSION} (${email})`;
  if (!warned) { warned = true; console.warn("VITALIS_CONTACT_EMAIL is not set; Open Food Facts asks for a contact e-mail in the User-Agent"); }
  return `Vitalis/${VERSION} (self-hosted)`;
}

/** One OFF call. `null` = unreachable/timeout/bad body; 404 bodies are still read (unknown products answer 404 + `status: 0`). */
async function callOff(url: string, kind: string): Promise<{ status: number; body: unknown } | null> {
  try {
    const res = await fetchImpl(url, { headers: { "User-Agent": userAgent(), Accept: "application/json" }, signal: AbortSignal.timeout(TIMEOUT_MS) });
    if (!res.ok && res.status !== 404) { console.warn(`Open Food Facts ${kind} failed: HTTP ${res.status}`); return null; }
    return { status: res.status, body: await res.json() };
  } catch (e) {
    console.warn(`Open Food Facts ${kind} failed: ${(e as Error)?.name ?? "error"}`);
    return null;
  }
}

const r1 = (x: number) => Math.round(x * 10) / 10;
function num(v: unknown): number | null {
  const n = typeof v === "number" ? v : typeof v === "string" && v.trim() !== "" ? Number(v) : NaN;
  return Number.isFinite(n) && n >= 0 ? n : null;
}
function str(v: unknown, max = 200): string | null {
  const s = Array.isArray(v) ? v.find((x) => typeof x === "string") : v;
  return typeof s === "string" && s.trim() ? s.trim().slice(0, max) : null;
}
const scale = (m: Macros, f: number): Macros => ({
  kcal: Math.round(m.kcal * f), protein_g: m.protein_g == null ? null : r1(m.protein_g * f),
  carbs_g: m.carbs_g == null ? null : r1(m.carbs_g * f), fat_g: m.fat_g == null ? null : r1(m.fat_g * f) });

/** OFF product/hit → item; null when there's no name or no `energy-kcal_100g` (spec: such hits are dropped / not found). */
function normalise(p: Record<string, unknown>): BarcodeItem | null {
  const n = (p.nutriments ?? {}) as Record<string, unknown>;
  const kcal = num(n["energy-kcal_100g"]), name = str(p.product_name);
  if (kcal == null || !name) return null;
  const per: Macros = { kcal, protein_g: num(n.proteins_100g), carbs_g: num(n.carbohydrates_100g), fat_g: num(n.fat_100g) };
  const sq = num(p.serving_quantity);
  const useSq = sq != null && sq > 0 && sq <= 5000;
  const grams = useSq ? r1(sq) : 100;
  const label = useSq ? (str(p.serving_size, 60)?.toUpperCase() ?? `${grams} G`) : "100 G";
  // Brands come as "A, B" from the product API and as an array from Search-a-licious; show the first.
  const brand = str(p.brands)?.split(",")[0].trim() || null;
  return { name, brand, quantity_label: str(p.quantity, 60)?.toUpperCase() ?? null, per_100g: scale(per, 1), serving: { label, grams, ...scale(per, grams / 100) } };
}

type EntryRow = { name: string; portion_text: string | null; grams: number | null; kcal: number; protein_g: number | null; carbs_g: number | null; fat_g: number | null; estimate: number };
type SavedRow = { id: string; name: string; items_json: string };

function localLabel(serving: string, tag: string) { return `${serving.toUpperCase()} · ${tag}`; }

/** Owner's own foods by case-insensitive substring: newest distinct entry names, then saved meals. Scans food_entries per search (single owner, small). */
function localMatches(q: string): SearchItem[] {
  const recent = all<EntryRow>(
    `SELECT name, portion_text, grams, kcal, protein_g, carbs_g, fat_g, estimate FROM (
       SELECT *, ROW_NUMBER() OVER (PARTITION BY lower(name) ORDER BY eaten_at DESC, created_at DESC) rn
       FROM food_entries WHERE deleted_at IS NULL AND instr(lower(name), ?) > 0)
     WHERE rn = 1 ORDER BY eaten_at DESC LIMIT ?`, q, LOCAL_MAX);
  const out: SearchItem[] = recent.map((e) => {
    const m: Macros = { kcal: Math.round(e.kcal), protein_g: e.protein_g, carbs_g: e.carbs_g, fat_g: e.fat_g };
    const label = e.portion_text?.trim() || (e.grams ? `${e.grams} g` : "1 serving");
    return { key: `recent:${e.name}`, name: e.name, brand: null, source: "recent", source_ref: null, estimate: !!e.estimate,
      per_100g: e.grams && e.grams > 0 ? scale(m, 100 / e.grams) : null, serving: { label: label.toUpperCase(), grams: e.grams, ...scale(m, 1) },
      label: localLabel(label, e.estimate ? "ESTIMATE" : "RECENT") };
  });
  if (out.length >= LOCAL_MAX) return out;
  const saved = all<SavedRow>("SELECT id, name, items_json FROM saved_meals WHERE deleted_at IS NULL AND instr(lower(name), ?) > 0 ORDER BY updated_at DESC LIMIT ?",
    q, LOCAL_MAX - out.length);
  for (const s of saved) {
    let items: Record<string, unknown>[] = [];
    try { const v = JSON.parse(s.items_json); if (Array.isArray(v)) items = v; } catch { /* corrupt row: show it with zeros */ }
    const sum = (k: string) => items.reduce((a, i) => a + (num(i[k]) ?? 0), 0);
    const has = (k: string) => items.some((i) => num(i[k]) != null);
    const grams = items.length && items.every((i) => num(i.grams) != null) ? sum("grams") : null;
    const m: Macros = { kcal: sum("kcal"), protein_g: has("protein_g") ? sum("protein_g") : null, carbs_g: has("carbs_g") ? sum("carbs_g") : null, fat_g: has("fat_g") ? sum("fat_g") : null };
    const label = `${items.length} item${items.length === 1 ? "" : "s"}`;
    out.push({ key: `saved:${s.id}`, name: s.name, brand: null, source: "saved", source_ref: s.id, estimate: false, per_100g: null,
      serving: { label: label.toUpperCase(), grams, ...scale(m, 1) }, label: localLabel(label, "SAVED") });
  }
  return out;
}

/** GET /v2/food/search. Local matches only on page 1 so paging through OFF results doesn't repeat them. */
export async function searchFood(qRaw: string, page = 1): Promise<SearchBody> {
  const q = String(qRaw ?? "").trim().toLowerCase().replace(/\s+/g, " ");
  if (q.length < 2) throw new ApiError(400, "Type at least 2 characters to search", "bad_request");
  if (q.length > MAX_Q) throw new ApiError(400, `Search text is limited to ${MAX_Q} characters`, "bad_request");
  if (!Number.isInteger(page) || page < 1 || page > MAX_PAGE) throw new ApiError(400, `page must be a whole number from 1 to ${MAX_PAGE}`, "bad_request");
  const local = page === 1 ? localMatches(q) : [];
  const now = clock();
  const done = (remote: SearchBody["remote"], hits: SearchItem[], next: number | null): SearchBody => {
    const results = [...local, ...hits];
    return { q, page, remote, count: results.length, results, next_page: next };
  };

  const cached = one<{ results_json: string; fetched_at: number }>("SELECT results_json, fetched_at FROM food_search_cache WHERE q=? AND page=?", q, page);
  if (cached && now - cached.fetched_at < SEARCH_TTL) {
    const c = JSON.parse(cached.results_json) as { results: SearchItem[]; next_page: number | null };
    return done("ok", c.results, c.next_page);
  }
  if (!take(searchBucket, now)) return done("rate_limited", [], null);
  const url = `https://search.openfoodfacts.org/search?q=${encodeURIComponent(q)}&page=${page}&page_size=20&fields=${SEARCH_FIELDS}`;
  const res = await callOff(url, "search");
  const body = (res?.status === 200 ? res.body : null) as { hits?: unknown; page_count?: unknown } | null;
  if (!body || !Array.isArray(body.hits)) return done("unavailable", [], null);

  const hits: SearchItem[] = [];
  for (const h of body.hits as Record<string, unknown>[]) {
    const code = str(h?.code, 32), item = code ? normalise(h) : null;
    if (!code || !item) continue;
    hits.push({ key: `off:${code}`, name: item.name, brand: item.brand, source: "search", source_ref: code, estimate: false,
      per_100g: item.per_100g, serving: item.serving, label: `${item.serving.label} · OPEN FOOD FACTS` });
  }
  const pageCount = num(body.page_count) ?? 0;
  const next = page < pageCount && page < MAX_PAGE ? page + 1 : null;
  tx(() => {
    run("DELETE FROM food_search_cache WHERE fetched_at < ?", now - SEARCH_TTL);
    run("INSERT OR REPLACE INTO food_search_cache (q, page, results_json, fetched_at) VALUES (?,?,?,?)", q, page, JSON.stringify({ results: hits, next_page: next }), now);
  });
  return done("ok", hits, next);
}

type BarcodeRow = { status: "found" | "missing" | "user"; item_json: string | null; fetched_at: number };

function barcodeBody(code: string, row: Pick<BarcodeRow, "status" | "item_json">): BarcodeBody {
  if (row.status === "missing" || !row.item_json) return { code, found: false, source: "openfoodfacts", item: null, label: NOT_FOUND_LABEL };
  const item = JSON.parse(row.item_json) as BarcodeItem;
  const you = row.status === "user";
  return { code, found: true, source: you ? "you" : "openfoodfacts", item, label: `${item.serving.label} · ${you ? "YOURS" : "OPEN FOOD FACTS"}` };
}

function checkCode(code: string) {
  if (!/^\d{8,14}$/.test(code)) throw new ApiError(400, "A barcode is 8 to 14 digits", "bad_request");
}

/**
 * GET /v2/food/barcode/:code. When OFF can't be asked (bucket empty → 429) or fails (→ 503), a stale cached row
 * is returned instead; the errors only surface with nothing cached (spec §1.3 table).
 */
export async function barcode(code: string): Promise<BarcodeBody> {
  checkCode(code);
  const now = clock();
  const row = one<BarcodeRow>("SELECT status, item_json, fetched_at FROM food_barcodes WHERE code=?", code);
  if (row?.status === "user") return barcodeBody(code, row);
  if (row && now - row.fetched_at < (row.status === "found" ? FOUND_TTL : MISSING_TTL)) return barcodeBody(code, row);

  if (!take(productBucket, now)) {
    if (row) return barcodeBody(code, row);
    throw new ApiError(429, "Too many barcode lookups; try again in a minute", "rate_limited");
  }
  const res = await callOff(`https://world.openfoodfacts.org/api/v2/product/${code}?fields=${PRODUCT_FIELDS}`, "product");
  const body = (res?.body ?? null) as { status?: unknown; product?: unknown } | null;
  const st = body && typeof body === "object" ? Number(body.status) : NaN;
  if (st !== 0 && !(st === 1 && body?.product && typeof body.product === "object")) {
    if (row) return barcodeBody(code, row);
    throw new ApiError(503, "Open Food Facts can't be reached right now", "unavailable");
  }
  const item = st === 1 ? normalise(body!.product as Record<string, unknown>) : null;
  const next = { status: item ? "found" : "missing", item_json: item ? JSON.stringify(item) : null } as const;
  run("INSERT OR REPLACE INTO food_barcodes (code, status, item_json, fetched_at) VALUES (?,?,?,?)", code, next.status, next.item_json, now);
  return barcodeBody(code, next);
}

const macro = z.number().min(0).max(1000);
const macros = { protein_g: macro.nullish(), carbs_g: macro.nullish(), fat_g: macro.nullish() };
/** PUT /v2/food/barcode/:code body: the owner's fallback for a code OFF doesn't know. */
export const barcodePutSchema = z.object({
  item: z.object({
    name: z.string().trim().min(1).max(120),
    brand: z.string().trim().max(120).nullish(),
    serving: z.object({ label: z.string().trim().min(1).max(40), grams: z.number().positive().max(5000).nullish(), kcal: z.number().min(0).max(10000), ...macros }),
    per_100g: z.object({ kcal: z.number().min(0).max(1000), ...macros }).nullish(),
  }),
});
export type BarcodePut = z.infer<typeof barcodePutSchema>;

/** Stores the owner's item as status 'user'; it wins over OFF from then on and is kept forever. */
export function putBarcode(code: string, input: BarcodePut["item"]): BarcodeBody {
  checkCode(code);
  const s = input.serving;
  const m: Macros = { kcal: s.kcal, protein_g: s.protein_g ?? null, carbs_g: s.carbs_g ?? null, fat_g: s.fat_g ?? null };
  const p = input.per_100g;
  const per = p ? scale({ kcal: p.kcal, protein_g: p.protein_g ?? null, carbs_g: p.carbs_g ?? null, fat_g: p.fat_g ?? null }, 1)
    : s.grams ? scale(m, 100 / s.grams) : null;
  const item: BarcodeItem = { name: input.name, brand: input.brand || null, quantity_label: null, per_100g: per,
    serving: { label: s.label.toUpperCase(), grams: s.grams ?? null, ...scale(m, 1) } };
  run("INSERT OR REPLACE INTO food_barcodes (code, status, item_json, fetched_at) VALUES (?,'user',?,?)", code, JSON.stringify(item), clock());
  return barcodeBody(code, { status: "user", item_json: JSON.stringify(item) });
}
