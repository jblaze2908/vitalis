// The metrics agents can ask for: one stable key, one fixed unit, and which direction is good. Health Auto Export names
// map onto these keys and its units are converted at ingest; any other metric is kept under its own name and unit.

export type Polarity = "higher" | "lower" | "neutral";
export type MetricDef = { key: string; hae: string; unit: string; polarity: Polarity; label: string; band?: boolean };

export const METRICS: MetricDef[] = [
  { key: "resting_hr", hae: "resting_heart_rate", unit: "bpm", polarity: "lower", label: "resting heart rate" },
  { key: "hrv", hae: "heart_rate_variability", unit: "ms", polarity: "higher", label: "heart rate variability (SDNN)" },
  { key: "heart_rate", hae: "heart_rate", unit: "bpm", polarity: "neutral", label: "heart rate (daily min, avg, max)", band: true },
  { key: "respiratory_rate", hae: "respiratory_rate", unit: "breaths/min", polarity: "neutral", label: "breathing rate during sleep" },
  { key: "spo2", hae: "blood_oxygen_saturation", unit: "%", polarity: "higher", label: "blood oxygen" },
  { key: "wrist_temp", hae: "apple_sleeping_wrist_temperature", unit: "°C", polarity: "neutral", label: "wrist temperature during sleep" },
  { key: "steps", hae: "step_count", unit: "steps", polarity: "higher", label: "steps" },
  { key: "active_kcal", hae: "active_energy", unit: "kcal", polarity: "higher", label: "active energy (Watch estimate)" },
  { key: "resting_kcal", hae: "basal_energy_burned", unit: "kcal", polarity: "neutral", label: "resting energy (Watch estimate)" },
  { key: "exercise_min", hae: "apple_exercise_time", unit: "min", polarity: "higher", label: "exercise minutes" },
  { key: "stand_hours", hae: "apple_stand_hour", unit: "hours", polarity: "higher", label: "stand hours" },
  { key: "distance_km", hae: "walking_running_distance", unit: "km", polarity: "higher", label: "walking and running distance" },
  { key: "flights", hae: "flights_climbed", unit: "flights", polarity: "higher", label: "flights climbed" },
  { key: "daylight_min", hae: "time_in_daylight", unit: "min", polarity: "higher", label: "time in daylight" },
  { key: "walking_hr", hae: "walking_heart_rate_average", unit: "bpm", polarity: "lower", label: "walking heart rate" },
  { key: "vo2max", hae: "vo2_max", unit: "ml/kg/min", polarity: "higher", label: "VO2 max (Watch estimate)" },
  { key: "weight_kg", hae: "weight_body_mass", unit: "kg", polarity: "neutral", label: "body weight" },
  { key: "body_fat_pct", hae: "body_fat_percentage", unit: "%", polarity: "neutral", label: "body fat" },
];
// Derived from sleep_nights, not stored as metric rows.
export const SLEEP_METRICS: MetricDef[] = [
  { key: "sleep_h", hae: "", unit: "hours", polarity: "higher", label: "time asleep" },
  { key: "bedtime", hae: "", unit: "clock", polarity: "neutral", label: "time fell asleep" },
  { key: "deep_h", hae: "", unit: "hours", polarity: "higher", label: "deep sleep" },
  { key: "rem_h", hae: "", unit: "hours", polarity: "higher", label: "REM sleep" },
];

export const BY_KEY = new Map([...METRICS, ...SLEEP_METRICS].map((m) => [m.key, m]));
export const BY_HAE = new Map(METRICS.map((m) => [m.hae, m]));

/** Convert a Health Auto Export value into the metric's fixed unit; null when the unit is unknown for a known metric. */
export function convert(def: MetricDef | undefined, value: number, unit: string): number | null {
  if (!def) return value;
  const u = unit.trim().toLowerCase();
  switch (def.unit) {
    case "kcal": return u === "kj" ? value / 4.184 : u === "kcal" || u === "cal" ? value : null;
    case "kg": return u === "kg" ? value : u === "lb" || u === "lbs" ? value * 0.45359237 : u === "g" ? value / 1000 : null;
    case "km": return u === "km" ? value : u === "mi" ? value * 1.609344 : u === "m" ? value / 1000 : null;
    case "°C": return u === "degc" || u === "°c" ? value : u === "degf" || u === "°f" ? ((value - 32) * 5) / 9 : null;
    case "%": return u === "%" ? (value <= 1 && def.key === "spo2" ? value * 100 : value) : null;
    default: return value;
  }
}

/** Major groups for "what haven't I trained", in free-exercise-db's muscle names. */
export const MAJOR_MUSCLES = ["chest", "lats", "middle back", "shoulders", "biceps", "triceps", "quadriceps", "hamstrings", "glutes", "calves", "abdominals"];
