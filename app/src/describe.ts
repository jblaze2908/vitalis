// Describe (spec 10 §7): free text → estimated food items. Stores nothing; the route's audit writes the only calls row.
import { z } from "zod";
import { SLOTS } from "./food.js";
import { ApiError } from "./http.js";

export const DESCRIBE_LIMIT_PER_HOUR = 30;
export const DESCRIBE_TIMEOUT_MS = 20_000;
export const DESCRIBE_NOTE = "ESTIMATED FROM YOUR WORDS · CHECK PORTIONS BEFORE ADDING";
const UNAVAILABLE = "Describe isn't set up on this server";
const MAX_ITEMS = 12;
const HOUR_MS = 3_600_000;

export const DescribeRequest = z.object({ text: z.string().trim().min(3).max(500), slot: z.enum(SLOTS) });
export type DescribeInput = z.infer<typeof DescribeRequest>;

// Macros and grams are nullable (food_entries allows it): "unknown" beats an invented 0 g protein.
const DescribedItemSchema = z.object({
  name: z.string().trim().min(1).max(120),
  portion_text: z.string().trim().min(1).max(60),
  grams: z.number().min(0).max(5000).nullable(),
  kcal: z.number().min(0).max(5000),
  protein_g: z.number().min(0).max(1000).nullable(),
  carbs_g: z.number().min(0).max(1000).nullable(),
  fat_g: z.number().min(0).max(1000).nullable(),
  confidence: z.enum(["high", "medium", "low"]),
  portion_options: z.array(z.object({ label: z.string().trim().min(1).max(40), factor: z.number().positive().max(10) })).min(1).max(6),
});
export const ParserOutput = z.array(DescribedItemSchema).max(MAX_ITEMS);
export type DescribedItem = z.infer<typeof DescribedItemSchema>;

export interface MealParser {
  /** `signal` aborts when Describe times out, so a provider can cancel its request. */
  parse(text: string, slot: string, signal?: AbortSignal): Promise<DescribedItem[]>;
}

export type DescribeMode = "off" | "fixture" | "anthropic";
/** Read per call so the mode can change without a restart (and tests can flip it). Unknown values fail closed to off. */
export function describeMode(): DescribeMode {
  const v = (process.env.VITALIS_DESCRIBE ?? "off").trim().toLowerCase();
  return v === "fixture" || v === "anthropic" ? v : "off";
}

// ---- FixtureParser -------------------------------------------------------------------------------------------------

type Dish = { name: string; aliases: string[]; unit: [string, string]; grams: number; kcal: number; p: number; c: number; f: number; confidence: "high" | "medium" };
// Per one unit; synthetic, typical home portions.
const DISHES: Dish[] = [
  { name: "Roti", aliases: ["roti", "chapati", "phulka"], unit: ["roti", "rotis"], grams: 40, kcal: 120, p: 3.5, c: 22, f: 2, confidence: "high" },
  { name: "Rice", aliases: ["rice", "steamed rice", "chawal"], unit: ["bowl", "bowls"], grams: 150, kcal: 195, p: 4, c: 42, f: 0.5, confidence: "medium" },
  { name: "Dal", aliases: ["dal", "daal", "dhal"], unit: ["bowl", "bowls"], grams: 150, kcal: 170, p: 9, c: 24, f: 4, confidence: "medium" },
  { name: "Paneer tikka", aliases: ["paneer tikka"], unit: ["plate", "plates"], grams: 200, kcal: 420, p: 28, c: 12, f: 29, confidence: "medium" },
  { name: "Chicken curry", aliases: ["chicken curry"], unit: ["bowl", "bowls"], grams: 200, kcal: 300, p: 25, c: 8, f: 18, confidence: "medium" },
  { name: "Egg", aliases: ["egg", "boiled egg"], unit: ["egg", "eggs"], grams: 50, kcal: 72, p: 6, c: 0.5, f: 5, confidence: "high" },
  { name: "Omelette", aliases: ["omelette", "omelet"], unit: ["omelette", "omelettes"], grams: 120, kcal: 190, p: 13, c: 2, f: 14, confidence: "medium" },
  { name: "Idli", aliases: ["idli", "idly"], unit: ["idli", "idlis"], grams: 40, kcal: 58, p: 2, c: 12, f: 0.2, confidence: "high" },
  { name: "Dosa", aliases: ["dosa", "plain dosa"], unit: ["dosa", "dosas"], grams: 100, kcal: 170, p: 4, c: 28, f: 5, confidence: "medium" },
  { name: "Poha", aliases: ["poha"], unit: ["plate", "plates"], grams: 180, kcal: 250, p: 5, c: 45, f: 6, confidence: "medium" },
  { name: "Upma", aliases: ["upma"], unit: ["bowl", "bowls"], grams: 180, kcal: 230, p: 6, c: 34, f: 8, confidence: "medium" },
  { name: "Curd", aliases: ["curd", "dahi", "yogurt", "yoghurt"], unit: ["bowl", "bowls"], grams: 150, kcal: 90, p: 5, c: 7, f: 5, confidence: "high" },
  { name: "Banana", aliases: ["banana"], unit: ["banana", "bananas"], grams: 120, kcal: 105, p: 1.3, c: 27, f: 0.4, confidence: "high" },
  { name: "Apple", aliases: ["apple"], unit: ["apple", "apples"], grams: 180, kcal: 95, p: 0.5, c: 25, f: 0.3, confidence: "high" },
  { name: "Oats", aliases: ["oats", "oatmeal", "porridge"], unit: ["bowl", "bowls"], grams: 250, kcal: 150, p: 5, c: 27, f: 3, confidence: "medium" },
  { name: "Milk", aliases: ["milk"], unit: ["glass", "glasses"], grams: 250, kcal: 150, p: 8, c: 12, f: 8, confidence: "high" },
  { name: "Coffee", aliases: ["coffee"], unit: ["cup", "cups"], grams: 150, kcal: 60, p: 2, c: 8, f: 2, confidence: "medium" },
  { name: "Tea", aliases: ["tea", "chai"], unit: ["cup", "cups"], grams: 150, kcal: 70, p: 2, c: 10, f: 2, confidence: "medium" },
  { name: "Chicken breast", aliases: ["chicken breast", "grilled chicken"], unit: ["piece", "pieces"], grams: 150, kcal: 230, p: 46, c: 0, f: 5, confidence: "medium" },
  { name: "Salad", aliases: ["salad", "green salad"], unit: ["bowl", "bowls"], grams: 150, kcal: 80, p: 2, c: 10, f: 4, confidence: "medium" },
  { name: "Sandwich", aliases: ["sandwich"], unit: ["sandwich", "sandwiches"], grams: 150, kcal: 300, p: 12, c: 35, f: 12, confidence: "medium" },
];
const ALIASES = new Map<string, Dish>();
for (const d of DISHES) for (const a of [...d.aliases, d.unit[1]]) ALIASES.set(a, d);
const ALIAS_RES = [...ALIASES.keys()].sort((a, b) => b.length - a.length).map((a) => [a, new RegExp(`\\b${a}\\b`)] as const);

// Separators: comma, semicolon, newline, "&", "+", and whole-word "and" / "with" ("sandwich" must survive).
const SPLIT = /\s*[,;\n&+]\s*|\s+(?:and|with)\s+/i;
const WORD_QTY: Record<string, number> = { a: 1, an: 1, one: 1, two: 2, three: 3, four: 4, five: 5, six: 6, half: 0.5, quarter: 0.25 };
const GLYPH_QTY: Record<string, number> = { "½": 0.5, "¼": 0.25, "¾": 0.75 };
// Containers are consumed but do not change the dish's own unit: "a bowl of dal" is 1 × the dal portion.
const CONTAINER = /^(?:plates?|bowls?|katoris?|cups?|glass(?:es)?|pieces?|slices?|servings?|portions?|helpings?)\s+(?:of\s+)?/;

function leadingQuantity(s: string): [number, string] {
  let m = s.match(/^(\d+)\s*\/\s*(\d+)\s*/);
  if (m && Number(m[2]) > 0) return [Number(m[1]) / Number(m[2]), s.slice(m[0].length)];
  m = s.match(/^(\d+(?:\.\d+)?)?\s*([½¼¾])?\s*(?:x\s+)?/);
  if (m && (m[1] || m[2])) return [Number(m[1] ?? 0) + (m[2] ? GLYPH_QTY[m[2]] : 0), s.slice(m[0].length)];
  m = s.match(/^(half\s+an?|a\s+half|[a-z]+)\s+/);
  if (m) {
    const w = m[1].replace(/\s+/g, " ");
    const q = w.startsWith("half") || w === "a half" ? 0.5 : WORD_QTY[w];
    if (q !== undefined) return [q, s.slice(m[0].length)];
  }
  return [1, s];
}

const FRACTION: Record<string, string> = { "0.25": "¼", "0.5": "½", "0.75": "¾" };
function fmtQty(n: number) {
  const whole = Math.floor(n + 1e-9), frac = Number((n - whole).toFixed(2));
  if (frac === 0) return String(whole);
  const glyph = FRACTION[String(frac)];
  return glyph ? `${whole || ""}${glyph}` : String(Number(n.toFixed(2)));
}
const label = (n: number, [one, many]: [string, string]) => `${fmtQty(n)} ${n > 1 ? many : one}`;
const titleCase = (s: string) => s.replace(/\b\p{L}/gu, (ch) => ch.toUpperCase());
const options = (qty: number, unit: [string, string]) => [0.5, 1, 1.5].map((factor) => ({ label: label(qty * factor, unit), factor }));

function findDish(phrase: string): { dish: Dish; exact: boolean } | null {
  const exact = ALIASES.get(phrase) ?? ALIASES.get(phrase.replace(/s$/, ""));
  if (exact) return { dish: exact, exact: true };
  const hit = ALIAS_RES.find(([, re]) => re.test(phrase));
  return hit ? { dish: ALIASES.get(hit[0])!, exact: false } : null;
}

/** Deterministic parser for tests and `fixture` mode; ignores `slot`, keeps the first 12 pieces.
 *  Unknown dish: 300 kcal per serving, grams and macros null, confidence "low". */
export class FixtureParser implements MealParser {
  async parse(text: string): Promise<DescribedItem[]> {
    const pieces = text.toLowerCase().split(SPLIT).map((s) => s.replace(/[.!?"]+/g, " ").replace(/\s+/g, " ").trim().replace(/^(?:and|with)\s+/, "")).filter(Boolean);
    return pieces.slice(0, MAX_ITEMS).map((piece) => {
      const [qty, rest] = leadingQuantity(piece);
      const phrase = rest.replace(CONTAINER, "").replace(/^of\s+/, "").trim() || rest.trim() || piece;
      const found = findDish(phrase);
      if (!found) {
        const unit: [string, string] = ["serving", "servings"];
        return { name: titleCase(phrase).slice(0, 120), portion_text: label(qty, unit), grams: null, kcal: Math.round(300 * qty),
          protein_g: null, carbs_g: null, fat_g: null, confidence: "low" as const, portion_options: options(qty, unit) };
      }
      const { dish, exact } = found;
      return { name: dish.name, portion_text: label(qty, dish.unit), grams: Math.round(dish.grams * qty), kcal: Math.round(dish.kcal * qty),
        protein_g: Math.round(dish.p * qty), carbs_g: Math.round(dish.c * qty), fat_g: Math.round(dish.f * qty),
        confidence: exact ? dish.confidence : "medium" as const, portion_options: options(qty, dish.unit) };
    });
  }
}

/** Provider stub: awaits the owner's approval of the LLM SDK dependency (spec 50 Q1); until then `anthropic` is a 503. */
export class AnthropicParserNotConfigured implements MealParser {
  async parse(): Promise<DescribedItem[]> { throw new ApiError(503, UNAVAILABLE, "unavailable"); }
}

// ---- describe ------------------------------------------------------------------------------------------------------

const hits = new Map<string, number[]>();
export function resetDescribeLimits() { hits.clear(); }

/** Rolling hour per token, in memory (resets on restart). Counts attempts, so timeouts and failures use quota too. */
function takeQuota(tokenId: string, now: number) {
  const recent = (hits.get(tokenId) ?? []).filter((t) => t > now - HOUR_MS);
  if (recent.length >= DESCRIBE_LIMIT_PER_HOUR) {
    hits.set(tokenId, recent);
    const retry = Math.max(1, Math.ceil((recent[0] + HOUR_MS - now) / 1000));
    throw new ApiError(429, `Describe allows ${DESCRIBE_LIMIT_PER_HOUR} requests an hour; try again in ${Math.ceil(retry / 60)} min`, "rate_limited", { retry_after_s: retry });
  }
  recent.push(now);
  hits.set(tokenId, recent);
}

async function withTimeout<T>(run: (signal: AbortSignal) => Promise<T>, ms: number): Promise<T> {
  const ac = new AbortController();
  let timer: NodeJS.Timeout | undefined;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => { ac.abort(); reject(new ApiError(504, "Describe took too long; try a shorter description", "describe_timeout")); }, ms);
  });
  try { return await Promise.race([run(ac.signal), timeout]); } finally { clearTimeout(timer); }
}

const sum = (items: DescribedItem[], k: "kcal" | "protein_g" | "carbs_g" | "fat_g") => Math.round(items.reduce((a, it) => a + (it[k] ?? 0), 0));
const round = (n: number | null) => n === null ? null : Math.round(n);

/** 503 off/stub → 429 over quota → 504 slow parser → 502 bad parser output. Never touches the database. */
export async function describe(input: DescribeInput, tokenId: string, parser?: MealParser, opts: { now?: number; timeoutMs?: number } = {}) {
  const mode = describeMode();
  if (mode === "off") throw new ApiError(503, UNAVAILABLE, "unavailable");
  const req = DescribeRequest.safeParse(input);
  if (!req.success) {
    const i = req.error.issues[0];
    throw new ApiError(422, `${i.path.join(".") || "body"}: ${i.message}`, "invalid");
  }
  takeQuota(tokenId, opts.now ?? Date.now());
  const p = parser ?? (mode === "fixture" ? new FixtureParser() : new AnthropicParserNotConfigured());
  let raw: unknown;
  try {
    raw = await withTimeout((signal) => p.parse(req.data.text, req.data.slot, signal), opts.timeoutMs ?? DESCRIBE_TIMEOUT_MS);
  } catch (e) {
    if (e instanceof ApiError) throw e;
    console.error("describe parser failed:", e);
    throw new ApiError(502, "Describe couldn't read that meal; try again or add items by hand", "describe_failed");
  }
  const out = ParserOutput.safeParse(raw);
  if (!out.success) throw new ApiError(502, "Describe couldn't read that meal; try again or add items by hand", "describe_failed");
  // Integers on items and totals keep "total = sum of items" exact for the app.
  const items = out.data.map((it) => ({ ...it, grams: round(it.grams), kcal: Math.round(it.kcal), protein_g: round(it.protein_g),
    carbs_g: round(it.carbs_g), fat_g: round(it.fat_g) }));
  return {
    items,
    total: { kcal: sum(items, "kcal"), protein_g: sum(items, "protein_g"), carbs_g: sum(items, "carbs_g"), fat_g: sum(items, "fat_g") },
    estimate: true as const,
    note: DESCRIBE_NOTE,
  };
}
