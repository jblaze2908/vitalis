// Native units are explicit; never label an unknown unit with the catalog's fixed unit.
import { BY_KEY, type MetricDef } from "./catalog.js";
import { TZ } from "./config.js";

type Mapping = { def: MetricDef; cumulative: boolean };
const types: [string, string, boolean][] = [
  ["RestingHeartRate", "resting_hr", false], ["HeartRateVariabilitySDNN", "hrv", false], ["HeartRate", "heart_rate", false],
  ["RespiratoryRate", "respiratory_rate", false], ["OxygenSaturation", "spo2", false], ["AppleSleepingWristTemperature", "wrist_temp", false],
  ["StepCount", "steps", true], ["ActiveEnergyBurned", "active_kcal", true], ["BasalEnergyBurned", "resting_kcal", true],
  ["AppleExerciseTime", "exercise_min", true], ["DistanceWalkingRunning", "distance_km", true],
  ["FlightsClimbed", "flights", true], ["TimeInDaylight", "daylight_min", true], ["WalkingHeartRateAverage", "walking_hr", false],
  ["VO2Max", "vo2max", false], ["BodyMass", "weight_kg", false], ["BodyFatPercentage", "body_fat_pct", false],
];
export const HK_METRICS = new Map<string, Mapping>(types.map(([type, key, cumulative]) => [`HKQuantityTypeIdentifier${type}`, { def: BY_KEY.get(key)!, cumulative }]));
export const STAND_TYPE = "HKCategoryTypeIdentifierAppleStandHour";
HK_METRICS.set(STAND_TYPE, { def: BY_KEY.get("stand_hours")!, cumulative: true });
export const SLEEP_TYPE = "HKCategoryTypeIdentifierSleepAnalysis";
export const HR_TYPE = "HKQuantityTypeIdentifierHeartRate";

export function nativeValue(key: string, value: number, unit: string): number | null {
  const u = unit.trim().toLowerCase();
  switch (BY_KEY.get(key)?.unit) {
    case "bpm": case "breaths/min": return ["count/min", "bpm", "breaths/min"].includes(u) ? value : u === "count/s" ? value * 60 : null;
    case "ms": return u === "ms" ? value : u === "s" ? value * 1000 : null;
    case "kcal": return u === "kcal" ? value : u === "kj" ? value / 4.184 : u === "j" ? value / 4184 : null;
    case "kg": return u === "kg" ? value : u === "g" ? value / 1000 : ["lb", "lbs"].includes(u) ? value * 0.45359237 : null;
    case "km": return u === "km" ? value : u === "m" ? value / 1000 : u === "mi" ? value * 1.609344 : null;
    case "°C": return ["degc", "°c"].includes(u) ? value : ["degf", "°f"].includes(u) ? (value - 32) * 5 / 9 : null;
    case "%": return u === "%" ? value * 100 : null; // HKUnit.percent(): 1.0 represents 100%.
    case "min": return u === "min" ? value : u === "s" ? value / 60 : ["h", "hr"].includes(u) ? value * 60 : null;
    case "hours": return ["h", "hr"].includes(u) ? value : u === "min" ? value / 60 : u === "s" ? value / 3600 : null;
    case "steps": case "flights": return ["count", "steps", "flights"].includes(u) ? value : null;
    case "ml/kg/min": return ["ml/kg/min", "ml/(kg*min)", "ml/(kg·min)"].includes(u) ? value : null;
    default: return null;
  }
}

const formatters = new Map<string, Intl.DateTimeFormat>();
export function dayAt(ms: number, iso: string, tz?: string | null): string {
  if (!tz) {
    const m = /([+-])(\d{2}):(\d{2})$/.exec(iso);
    if (m) return new Date(ms + (m[1] === "-" ? -1 : 1) * (+m[2] * 60 + +m[3]) * 60_000).toISOString().slice(0, 10);
    // Z is an explicit offset too. TZ is only a defensive fallback for internal callers.
    if (iso.endsWith("Z")) return new Date(ms).toISOString().slice(0, 10);
    tz = TZ;
  }
  let f = formatters.get(tz);
  if (!f) { f = new Intl.DateTimeFormat("en-CA", { timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit" }); formatters.set(tz, f); }
  return f.format(ms);
}

/** Split at actual local midnight, including DST changes; the final endpoint is exclusive. */
export function splitDays(start: number, end: number, iso: string, tz?: string | null) {
  const out: { day: string; start: number; end: number; fraction: number }[] = [];
  let at = start;
  do {
    const day = dayAt(at, iso, tz);
    let stop = end;
    if (end > at && dayAt(end - 1, iso, tz) !== day) {
      let lo = at + 1, hi = Math.min(end, at + 27 * 3_600_000);
      while (lo < hi) { const mid = Math.floor((lo + hi) / 2); if (dayAt(mid, iso, tz) === day) lo = mid + 1; else hi = mid; }
      stop = lo;
    }
    out.push({ day, start: at, end: stop, fraction: end === start ? 1 : (stop - at) / (end - start) });
    at = stop;
  } while (at < end);
  return out;
}
