// The exercise catalogue: free-exercise-db (public domain, Unlicense) seeded once, plus the owner's custom exercises.
// Names resolve by exact id, exact name or alias, then by word overlap; an unclear name returns candidates, never a guess.
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { httpErr, now } from "./config.js";
import { all, db, one, run, tx } from "./db.js";

export type Exercise = { id: string; name: string; equipment: string | null; mechanic: string | null; category: string | null;
  primary: string[]; secondary: string[]; aliases: string[]; custom: boolean };
type Raw = { id: string; name: string; equipment: string | null; mechanic: string | null; category: string | null; primary: string[]; secondary: string[] };
type Row = { id: string; name: string; equipment: string | null; mechanic: string | null; category: string | null; primary_muscles: string;
  secondary_muscles: string; aliases: string; custom: number };

// What people actually say in a gym, mapped to catalogue ids.
const ALIASES: Record<string, string[]> = {
  "barbell-bench-press-medium-grip": ["bench", "bench press", "flat bench", "barbell bench"],
  "barbell-incline-bench-press-medium-grip": ["incline bench", "incline barbell press", "incline bench press"],
  "dumbbell-bench-press": ["db bench", "dumbbell press", "flat dumbbell press"],
  "incline-dumbbell-press": ["incline db press", "incline dumbbell bench"],
  "barbell-squat": ["squat", "back squat", "squats"],
  "barbell-deadlift": ["deadlift", "deadlifts", "conventional deadlift"],
  "romanian-deadlift": ["rdl", "romanian deadlift"],
  "standing-military-press": ["ohp", "overhead press", "military press", "standing press"],
  "dumbbell-shoulder-press": ["db shoulder press", "dumbbell overhead press"],
  "side-lateral-raise": ["lateral raise", "lateral raises", "side raise", "laterals"],
  "wide-grip-lat-pulldown": ["lat pulldown", "pulldown", "lat pull down"],
  "bent-over-barbell-row": ["barbell row", "bent over row", "row"],
  "one-arm-dumbbell-row": ["dumbbell row", "db row", "single arm row"],
  "seated-cable-rows": ["cable row", "seated row"],
  "pullups": ["pull up", "pull ups", "pullup"],
  "chin-up": ["chin up", "chin ups", "chinup"],
  "dips-triceps-version": ["dips", "dip"],
  "triceps-pushdown": ["pushdown", "tricep pushdown", "triceps pushdown", "cable pushdown"],
  "triceps-pushdown-rope-attachment": ["rope pushdown"],
  "barbell-curl": ["curl", "bicep curl", "barbell curls"],
  "dumbbell-bicep-curl": ["dumbbell curl", "db curl"],
  "hammer-curls": ["hammer curl"],
  "leg-press": ["leg press"],
  "leg-extensions": ["leg extension"],
  "lying-leg-curls": ["leg curl", "hamstring curl"],
  "seated-leg-curl": ["seated leg curl"],
  "standing-calf-raises": ["calf raise", "calf raises"],
  "barbell-hip-thrust": ["hip thrust", "hip thrusts"],
  "face-pull": ["face pulls"],
  "cable-crossover": ["cable fly", "cable flyes", "crossover"],
  "butterfly": ["pec deck", "pec fly", "machine fly"],
  "pushups": ["push up", "push ups", "pushup"],
  "ez-bar-skullcrusher": ["skull crusher", "skullcrusher", "skull crushers"],
  "goblet-squat": ["goblet squat"],
  "dumbbell-lunges": ["lunge", "lunges"],
};

export const norm = (s: string) => s.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
const slug = (s: string) => norm(s).replace(/ /g, "-");

export function seedExercises() {
  if (one<{ n: number }>("SELECT COUNT(*) n FROM exercises WHERE custom=0")!.n > 0) return;
  const file = fileURLToPath(new URL("../../data/exercises.json", import.meta.url));
  const list = JSON.parse(readFileSync(file, "utf8")) as Raw[];
  const ins = db.prepare("INSERT OR IGNORE INTO exercises(id,name,equipment,mechanic,category,primary_muscles,secondary_muscles,aliases,custom,created_at) VALUES(?,?,?,?,?,?,?,?,0,?)");
  tx(() => { for (const e of list) ins.run(e.id, e.name, e.equipment, e.mechanic, e.category, JSON.stringify(e.primary), JSON.stringify(e.secondary), JSON.stringify(ALIASES[e.id] ?? []), now()); });
}

const toEx = (r: Row): Exercise => ({ id: r.id, name: r.name, equipment: r.equipment, mechanic: r.mechanic, category: r.category,
  primary: JSON.parse(r.primary_muscles), secondary: JSON.parse(r.secondary_muscles), aliases: JSON.parse(r.aliases), custom: !!r.custom });
const COLS = "id,name,equipment,mechanic,category,primary_muscles,secondary_muscles,aliases,custom";

let cache: Exercise[] | null = null;
const catalogue = () => (cache ??= all<Row>(`SELECT ${COLS} FROM exercises`).map(toEx));
export const getExercise = (id: string) => catalogue().find((e) => e.id === id) ?? null;

/** Ranked matches for free text. Exact id, name or alias scores 100; otherwise shared words, favouring common lifts. */
export function findExercises(query: string, limit = 8): (Exercise & { score: number })[] {
  const q = norm(query), words = q.split(" ").filter(Boolean);
  if (!words.length) return [];
  const scored = catalogue().map((e) => {
    const names = [norm(e.name), ...e.aliases.map(norm)];
    if (e.id === slug(query) || names.includes(q)) return { ...e, score: 100 };
    const hay = new Set(names.join(" ").split(" "));
    const hit = words.filter((w) => hay.has(w) || [...hay].some((h) => h.startsWith(w) && w.length >= 3)).length;
    if (!hit) return { ...e, score: 0 };
    // Whole-query coverage first; then shorter names (the plain lift over its variants), aliased lifts and custom ones.
    const score = (hit / words.length) * 70 - norm(e.name).split(" ").length + (e.aliases.length ? 6 : 0) + (e.custom ? 8 : 0);
    return { ...e, score: Math.round(score) };
  });
  return scored.filter((e) => e.score > 0).sort((a, b) => b.score - a.score || a.name.localeCompare(b.name)).slice(0, limit);
}

export type Resolved = { exercise: Exercise } | { candidates: { id: string; name: string }[] };
/** One exercise for a name or id, or the candidates when it isn't clear which. */
export function resolveExercise(nameOrId: string): Resolved {
  const byId = getExercise(nameOrId);
  if (byId) return { exercise: byId };
  const hits = findExercises(nameOrId, 5);
  if (hits[0]?.score === 100) return { exercise: hits[0] };
  // Accept a clear winner: every word matched and well ahead of the next.
  if (hits[0] && hits[0].score >= 60 && (!hits[1] || hits[0].score - hits[1].score >= 10)) return { exercise: hits[0] };
  return { candidates: hits.map((h) => ({ id: h.id, name: h.name })) };
}

export function createExercise(input: { name: string; primary: string[]; secondary?: string[]; equipment?: string | null; aliases?: string[] }) {
  const id = `custom-${slug(input.name)}`;
  if (!slug(input.name)) throw httpErr(400, "Give the exercise a name");
  const existing = getExercise(id) ?? catalogue().find((e) => norm(e.name) === norm(input.name));
  if (existing) return { exercise: existing, created: false };
  run(`INSERT INTO exercises(${COLS},created_at) VALUES(?,?,?,?,?,?,?,?,1,?)`, id, input.name.trim(), input.equipment ?? null, null, "strength",
    JSON.stringify(input.primary), JSON.stringify(input.secondary ?? []), JSON.stringify((input.aliases ?? []).map((a) => a.trim()).filter(Boolean)), now());
  cache = null;
  return { exercise: getExercise(id)!, created: true };
}

export const MUSCLES = ["abdominals", "abductors", "adductors", "biceps", "calves", "chest", "forearms", "glutes", "hamstrings", "lats",
  "lower back", "middle back", "neck", "quadriceps", "shoulders", "traps", "triceps"];
