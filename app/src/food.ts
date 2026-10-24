// Food log (spec 10 §7): slots, day sums and entries. Fuel counts only Vitalis entries, never HealthKit dietary samples
// (prevents double counting what the phone also writes to Health).
import { all, one } from "./db.js";

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
