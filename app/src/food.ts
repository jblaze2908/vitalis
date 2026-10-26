// Food log (spec 10 §7): slots, day sums and entries. Fuel counts only Vitalis entries, never HealthKit dietary samples
// (prevents double counting what the phone also writes to Health).
import { randomUUID } from "node:crypto";
import { z } from "zod";
import { now } from "./config.js";
import { all, one, run, tx } from "./db.js";
import { markDirty } from "./derived.js";
import { freshnessBlock } from "./health.js";
import { ApiError } from "./http.js";
import { effectiveTargets } from "./targets.js";
import { addDays, isoAt, localDay, ownerOffsetMin, parseStamp, today } from "./time.js";
import { weekStartOf } from "./training-analytics.js";

export const SLOTS = ["breakfast", "lunch", "snack", "dinner"] as const;
export type Slot = (typeof SLOTS)[number];

/** Local windows: breakfast 04:00–10:29, lunch 10:30–14:59, snack 15:00–17:59, dinner 18:00–03:59. */
export function slotAt(minuteOfDay: number): Slot {
  const m = ((minuteOfDay % 1440) + 1440) % 1440;
  return m >= 240 && m < 630 ? "breakfast" : m >= 630 && m < 900 ? "lunch" : m >= 900 && m < 1080 ? "snack" : "dinner";
}

/** The current window's slot if nothing is logged in it yet, else the following one. */
export function nextSlot(day: string, minuteOfDay: number): Slot {
  const cur = slotAt(minuteOfDay);
  const has = !!one("SELECT 1 FROM food_entries WHERE day=? AND slot=? AND deleted_at IS NULL", day, cur);
  return has ? SLOTS[(SLOTS.indexOf(cur) + 1) % SLOTS.length] : cur;
}

export function daySums(day: string) {
  const r = one<{ kcal: number | null; protein_g: number | null; carbs_g: number | null; fat_g: number | null; n: number }>(
    "SELECT SUM(kcal) kcal, SUM(protein_g) protein_g, SUM(carbs_g) carbs_g, SUM(fat_g) fat_g, COUNT(*) n FROM food_entries WHERE day=? AND deleted_at IS NULL", day)!;
  return { kcal: r.kcal ?? 0, protein_g: r.protein_g ?? 0, carbs_g: r.carbs_g ?? 0, fat_g: r.fat_g ?? 0, entries: r.n };
}

/** First eaten_at of each add action on `day` (PulseLine meal dips). */
export const mealTimes = (day: string) => all<{ meal_id: string; at: number; off: number }>(
  "SELECT meal_id, MIN(eaten_at) at, tz_offset_min off FROM food_entries WHERE day=? AND deleted_at IS NULL GROUP BY meal_id ORDER BY at", day);

type EntryRow = { id: string; meal_id: string; day: string; slot: Slot; eaten_at: number; tz_offset_min: number; name: string; portion_text: string | null;
  grams: number | null; kcal: number; protein_g: number | null; carbs_g: number | null; fat_g: number | null; source: string; source_ref: string | null;
  estimate: number; hk_uuid: string | null; created_at: number; updated_at: number; deleted_at: number | null };

export const SOURCES = ["search", "barcode", "describe", "manual", "label_photo", "usual", "recent", "saved"] as const;
const macro = z.number().min(0).max(1000).nullable().optional();
export const entrySchema = z.strictObject({
  id: z.string().min(1).max(64), meal_id: z.string().min(1).max(64), slot: z.enum(SLOTS), eaten_at: z.string().min(10).max(40),
  name: z.string().trim().min(1).max(120), portion_text: z.string().max(120).nullable().optional(), grams: z.number().min(0).max(5000).nullable().optional(),
  kcal: z.number().min(0).max(10000), protein_g: macro, carbs_g: macro, fat_g: macro, source: z.enum(SOURCES),
  source_ref: z.string().max(64).nullable().optional(), estimate: z.boolean().optional(), hk_uuid: z.string().max(64).nullable().optional(),
});
export const entriesSchema = z.strictObject({ entries: z.array(entrySchema).min(1).max(50) });
const itemSchema = z.strictObject({ name: z.string().trim().min(1).max(120), portion_text: z.string().max(120).nullable().optional(),
  grams: z.number().min(0).max(5000).nullable().optional(), kcal: z.number().min(0).max(10000), protein_g: macro, carbs_g: macro, fat_g: macro });
export const savedSchema = z.strictObject({ id: z.string().min(1).max(64), name: z.string().trim().min(1).max(80), slot: z.enum(SLOTS).nullable().optional(),
  items: z.array(itemSchema).min(1).max(30) });

const MIN = 60_000;
const r1 = (v: number | null) => (v === null ? null : Math.round(v * 10) / 10);
const entryView = (e: EntryRow) => ({ id: e.id, meal_id: e.meal_id, name: e.name, portion_text: e.portion_text, grams: e.grams, kcal: Math.round(e.kcal),
  protein_g: r1(e.protein_g), carbs_g: r1(e.carbs_g), fat_g: r1(e.fat_g), estimate: !!e.estimate, source: e.source,
  // What an edit re-posts unchanged: the app updates an entry by sending it again with the same id.
  slot: e.slot, eaten_at: isoAt(e.eaten_at, e.tz_offset_min), source_ref: e.source_ref, hk_uuid: e.hk_uuid });
const itemView = (e: Pick<EntryRow, "name" | "portion_text" | "grams" | "kcal" | "protein_g" | "carbs_g" | "fat_g">) => ({ name: e.name, portion_text: e.portion_text,
  grams: e.grams, kcal: Math.round(e.kcal), protein_g: r1(e.protein_g), carbs_g: r1(e.carbs_g), fat_g: r1(e.fat_g) });
const sum = (xs: (number | null)[]) => xs.reduce<number>((a, b) => a + (b ?? 0), 0);

/** The usual meal for a slot (10 §7): the most frequent item set over 28 days, eaten at least 3 times; ties → most recent. */
export function usualFor(slot: Slot, day: string) {
  const rows = all<EntryRow>("SELECT * FROM food_entries WHERE slot=? AND day BETWEEN ? AND ? AND deleted_at IS NULL ORDER BY eaten_at", slot, addDays(day, -28), day);
  const meals = new Map<string, EntryRow[]>();
  for (const r of rows) meals.set(r.meal_id, [...(meals.get(r.meal_id) ?? []), r]);
  const bySig = new Map<string, { n: number; last: EntryRow[] }>();
  for (const items of meals.values()) {
    const sig = items.map((i) => i.name.trim().toLowerCase()).sort().join("|");
    const cur = bySig.get(sig);
    bySig.set(sig, { n: (cur?.n ?? 0) + 1, last: !cur || items[0].eaten_at >= cur.last[0].eaten_at ? items : cur.last });
  }
  const best = [...bySig].filter(([, v]) => v.n >= 3).sort(([, a], [, b]) => b.n - a.n || b.last[0].eaten_at - a.last[0].eaten_at)[0];
  if (!best) return null;
  const items = best[1].last;
  return { name: items.map((i) => i.name).join(", "), kcal: Math.round(sum(items.map((i) => i.kcal))), protein_g: r1(sum(items.map((i) => i.protein_g))),
    carbs_g: r1(sum(items.map((i) => i.carbs_g))), fat_g: r1(sum(items.map((i) => i.fat_g))), items: items.map(itemView), meal_signature: best[0] };
}

const DOW = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"], MON = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"];
const dateText = (day: string) => { const d = new Date(`${day}T00:00:00Z`); return `${DOW[d.getUTCDay()]} ${d.getUTCDate()} ${MON[d.getUTCMonth()]}`; };
const LABEL: Record<Slot, string> = { breakfast: "BREAKFAST", lunch: "LUNCH", snack: "SNACK", dinner: "DINNER" };

/** GET /v2/food/day body. `just_added` uses the server clock (10 minutes), like the JUST NOW label. */
export function foodDay(day: string, at = Date.now()) {
  const off = ownerOffsetMin(at), t = today(at);
  const entries = all<EntryRow>("SELECT * FROM food_entries WHERE day=? AND deleted_at IS NULL ORDER BY eaten_at, created_at", day);
  const tgt = effectiveTargets(at);
  const week = one<{ kcal: number }>("SELECT kcal FROM kcal_targets WHERE week_start=?", weekStartOf(day));
  const kcalTarget = tgt.kcal_mode === "fixed" || day >= weekStartOf(t) || !week ? tgt.kcal : week.kcal;
  const eaten = Math.round(sum(entries.map((e) => e.kcal))), left = kcalTarget - eaten;
  const mins = new Date(at + off * MIN), nowMin = mins.getUTCHours() * 60 + mins.getUTCMinutes();
  const slot = nextSlot(day, day === t ? nowMin : 12 * 60);
  return {
    day, date_label: `${day === t ? "TODAY · " : day === addDays(t, -1) ? "YESTERDAY · " : ""}${dateText(day)}`,
    prev_day: addDays(day, -1), next_day: day >= t ? null : addDays(day, 1),
    kcal_target: kcalTarget, kcal_eaten: eaten, kcal_left: left, over: left < 0,
    macros: { protein: { g: Math.round(sum(entries.map((e) => e.protein_g))), target_g: tgt.protein_g },
      carbs: { g: Math.round(sum(entries.map((e) => e.carbs_g))), target_g: null }, fat: { g: Math.round(sum(entries.map((e) => e.fat_g))), target_g: null } },
    target_note: tgt.kcal_mode === "fixed" ? null : `TARGET ${kcalTarget.toLocaleString("en-US")} KCAL ADJUSTS WEEKLY FROM YOUR WEIGHT TREND`,
    meals: SLOTS.map((s) => {
      const xs = entries.filter((e) => e.slot === s);
      if (!xs.length) return null;
      return { slot: s, label: LABEL[s], time: isoAt(xs[0].eaten_at, xs[0].tz_offset_min).slice(11, 16), kcal: Math.round(sum(xs.map((e) => e.kcal))),
        just_added: Math.max(...xs.map((e) => e.created_at)) > at - 10 * MIN, entries: xs.map(entryView) };
    }).filter(Boolean),
    next_slot: slot, usual_next: usualFor(slot, day), empty: entries.length === 0,
    freshness: freshnessBlock(at),
  };
}

/** GET /v2/food/quick body: the slot's usual, the last 10 distinct items, and saved meals. */
export function foodQuick(slot: Slot, at = Date.now()) {
  const recent = all<EntryRow>(`SELECT * FROM food_entries WHERE deleted_at IS NULL AND id IN (
    SELECT id FROM (SELECT id, ROW_NUMBER() OVER (PARTITION BY lower(name) ORDER BY eaten_at DESC, created_at DESC) rn FROM food_entries WHERE deleted_at IS NULL) WHERE rn=1)
    ORDER BY eaten_at DESC LIMIT 10`);
  return {
    slot, usual: usualFor(slot, today(at)),
    recent: recent.map((e) => ({ ...itemView(e), last_day: e.day })),
    saved: savedMeals(),
  };
}

export function savedMeals() {
  return all<{ id: string; name: string; slot: string | null; items_json: string }>("SELECT id,name,slot,items_json FROM saved_meals WHERE deleted_at IS NULL ORDER BY name")
    .map((m) => { const items = JSON.parse(m.items_json) as { kcal: number }[]; return { id: m.id, name: m.name, slot: m.slot, kcal: Math.round(sum(items.map((i) => i.kcal))), items }; });
}

const FIELDS = ["meal_id", "slot", "eaten_at", "tz_offset_min", "day", "name", "portion_text", "grams", "kcal", "protein_g", "carbs_g", "fat_g", "source", "source_ref", "estimate", "hk_uuid"] as const;

/** Idempotent by client id: same body → unchanged; changed body → update (and revive if deleted). Returns touched days. */
export function postEntries(input: z.infer<typeof entriesSchema>) {
  const rows = input.entries.map((e) => {
    const t = parseStamp(e.eaten_at);
    if (!t) throw new ApiError(422, `entries: eaten_at "${e.eaten_at}" isn't an ISO 8601 time with offset`, "invalid");
    if (t.ms > Date.now() + 10 * MIN) throw new ApiError(422, "entries: eaten_at is in the future", "invalid");
    return { id: e.id, meal_id: e.meal_id, slot: e.slot, eaten_at: t.ms, tz_offset_min: t.offsetMin, day: localDay(t.ms, t.offsetMin), name: e.name,
      portion_text: e.portion_text ?? null, grams: e.grams ?? null, kcal: e.kcal, protein_g: e.protein_g ?? null, carbs_g: e.carbs_g ?? null, fat_g: e.fat_g ?? null,
      source: e.source, source_ref: e.source_ref ?? null, estimate: e.estimate ? 1 : 0, hk_uuid: e.hk_uuid ?? null };
  });
  const accepted = { inserted: 0, updated: 0, unchanged: 0 }, days = new Set<string>();
  tx(() => {
    for (const r of rows) {
      const old = one<EntryRow>("SELECT * FROM food_entries WHERE id=?", r.id);
      if (old && FIELDS.every((k) => old[k] === r[k])) { accepted.unchanged++; continue; }
      const t = now();
      run(`INSERT INTO food_entries(id,${FIELDS.join(",")},created_at,updated_at) VALUES(?,${FIELDS.map(() => "?").join(",")},?,?)
        ON CONFLICT(id) DO UPDATE SET ${FIELDS.map((k) => `${k}=excluded.${k}`).join(",")},updated_at=excluded.updated_at,deleted_at=NULL`,
        r.id, ...FIELDS.map((k) => r[k]), t, t);
      if (old) { accepted.updated++; days.add(old.day); } else accepted.inserted++;
      days.add(r.day);
    }
    if (days.size) markDirty([...days]);
  });
  return { accepted, day: rows[0].day };
}

/** Soft-delete one entry or a whole add action; deleting twice is a 200 with deleted: 0. */
export function deleteEntries(by: "id" | "meal_id", value: string) {
  return tx(() => {
    const rows = all<EntryRow>(`SELECT * FROM food_entries WHERE ${by}=?`, value);
    if (!rows.length) throw new ApiError(404, `No food entry with ${by} ${value}`);
    const live = rows.filter((r) => r.deleted_at === null);
    if (live.length) {
      run(`UPDATE food_entries SET deleted_at=?,updated_at=? WHERE ${by}=? AND deleted_at IS NULL`, now(), now(), value);
      markDirty([...new Set(live.map((r) => r.day))]);
    }
    return { deleted: live.length, day: rows[0].day };
  });
}

export function putSaved(input: z.infer<typeof savedSchema>) {
  tx(() => {
    run(`INSERT INTO saved_meals(id,name,slot,items_json,created_at,updated_at) VALUES(?,?,?,?,?,?)
      ON CONFLICT(id) DO UPDATE SET name=excluded.name,slot=excluded.slot,items_json=excluded.items_json,updated_at=excluded.updated_at,deleted_at=NULL`,
      input.id, input.name, input.slot ?? null, JSON.stringify(input.items), now(), now());
    markDirty([]);
  });
  return { saved: savedMeals().find((m) => m.id === input.id)! };
}

/** A saved meal by id, else by name: exact (any case) first, then the only one whose name contains it. */
export function findSaved(ref: string) {
  const all = savedMeals(), q = ref.trim().toLowerCase();
  const hit = all.find((m) => m.id === ref) ?? all.find((m) => m.name.toLowerCase() === q);
  if (hit) return hit;
  const near = all.filter((m) => m.name.toLowerCase().includes(q) || q.includes(m.name.toLowerCase()));
  if (near.length === 1) return near[0];
  throw new ApiError(422, near.length ? `"${ref}" matches ${near.map((m) => m.name).join(", ")}; say which`
    : `No saved meal "${ref}". Saved: ${all.map((m) => m.name).join(", ") || "none yet"}`, "invalid");
}

const n = z.number().min(0).max(10000).nullable().optional();
/** MCP save_meal: one food's numbers inline, or several `items`; an existing name or id is replaced, `delete` removes it. */
export const saveMealSchema = z.strictObject({
  name: z.string().trim().min(1).max(80).describe("what the person calls it, e.g. 'Protein shake'"),
  id: z.string().min(1).max(64).optional().describe("only to rename a saved meal: its current id"),
  portion_text: z.string().max(120).nullable().optional(), kcal: n, protein_g: n, carbs_g: n, fat_g: n,
  items: z.array(itemSchema).min(1).max(30).optional().describe("for a meal of several foods, instead of the single-food numbers"),
  delete: z.boolean().optional(),
});
export function saveMeal(input: z.infer<typeof saveMealSchema>) {
  const existing = input.id ? findSaved(input.id) : savedMeals().find((m) => m.name.toLowerCase() === input.name.toLowerCase());
  if (input.delete) return deleteSaved((existing ?? findSaved(input.name)).id);
  if (!input.items && (input.kcal === undefined || input.kcal === null)) throw new ApiError(422, "kcal is required (or give items)", "invalid");
  const items = input.items ?? [{ name: input.name, portion_text: input.portion_text ?? null, kcal: input.kcal!, protein_g: input.protein_g ?? null,
    carbs_g: input.carbs_g ?? null, fat_g: input.fat_g ?? null }];
  return putSaved({ id: existing?.id ?? randomUUID(), name: input.name, items });
}

/** MCP log_saved_meal: a saved meal into the day, by name, in one call. */
export const logSavedSchema = z.strictObject({
  meal: z.string().min(1).max(80).describe("saved meal name or id"),
  servings: z.number().min(0.25).max(10).optional().describe("default 1"),
  slot: z.enum(SLOTS).optional().describe("default: the meal window at eaten_at"),
  eaten_at: z.string().min(10).max(40).optional().describe("ISO 8601 with offset; default now"),
  meal_id: z.string().min(1).max(64).optional().describe("your own id for this add, so a retry can't double-log"),
});
export function logSaved(input: z.infer<typeof logSavedSchema>, at = Date.now()) {
  const m = findSaved(input.meal), k = input.servings ?? 1, mealId = input.meal_id ?? randomUUID();
  const off = ownerOffsetMin(at), eatenAt = input.eaten_at ?? isoAt(at, off);
  const t = parseStamp(eatenAt);
  const slot = input.slot ?? slotAt(t ? Math.floor((t.ms + t.offsetMin * 60_000) / 60_000) % 1440 : 0);
  const x = (v: number | null | undefined) => (v == null ? null : Math.round(v * k * 10) / 10);
  const items = m.items as z.infer<typeof itemSchema>[];
  return postEntries({ entries: items.map((it, i) => ({ id: `${mealId}-${i}`, meal_id: mealId, slot, eaten_at: eatenAt, name: it.name,
    portion_text: k === 1 ? it.portion_text ?? null : `${k} × ${it.portion_text ?? "serving"}`, grams: x(it.grams), kcal: Math.round(it.kcal * k),
    protein_g: x(it.protein_g), carbs_g: x(it.carbs_g), fat_g: x(it.fat_g), source: "saved" as const, source_ref: m.id })) });
}

export function deleteSaved(id: string) {
  tx(() => {
    if (!one("SELECT 1 FROM saved_meals WHERE id=?", id)) throw new ApiError(404, `No saved meal ${id}`);
    run("UPDATE saved_meals SET deleted_at=COALESCE(deleted_at,?),updated_at=? WHERE id=?", now(), now(), id);
    markDirty([]);
  });
  return { saved: savedMeals() };
}
