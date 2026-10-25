// GET /v2/today and /v2/digest bodies (spec 10 §4). Builders take `at` (epoch ms) so clock-dependent rules are testable;
// routes pass Date.now(). Per call: scoresFor (cached window), trainingState (~30 days of sets), a few indexed sums.
import { expectedNow, pace, usualFractionNow, usualTotal } from "./activity.js";
import { all, one } from "./db.js";
import { featuresRange, scoresFor, tonightFor, trainingState, type Scores } from "./derived.js";
import { daySums, mealTimes, nextSlot, type Slot } from "./food.js";
import { stepsTarget } from "./fuel.js";
import { freshnessBlock } from "./health.js";
import { digestHeadline, verdict, type Verdict } from "./scoring.js";
import { baseline, daily, nights } from "./stats.js";
import { addDays, isoAt, localDay, ownerOffsetMin, today as todayOf } from "./time.js";
import { effectiveTargets } from "./targets.js";

const MIN = 60_000;
const DIGEST_SETTLE_MIN = 30;
const pad = (n: number) => String(n).padStart(2, "0");
const minuteOfDay = (ms: number, off: number) => { const d = new Date(ms + off * MIN); return d.getUTCHours() * 60 + d.getUTCMinutes(); };
/** Epoch ms of a local clock minute on `day` (minutes ≥ 1440 roll into the next day). */
const localMs = (day: string, minute: number, off: number) => Date.parse(`${day}T00:00:00Z`) + (minute - off) * MIN;
export const hmLabel = (h: number) => { const m = Math.round(h * 60); return `${Math.floor(m / 60)}H${pad(m % 60)}`; };
const fmt = (n: number) => Math.round(n).toLocaleString("en-US");

/** Recovery block as the API shows it: the scoring internals (raw z, per-part status) stay server-side. */
function recoveryView(s: Scores) {
  const r = s.recovery, heart = (p: Record<string, unknown>) => ({ value: p.value, unit: p.unit, ...(p.basis !== undefined && { basis: p.basis }),
    usual: p.usual, usual_range: p.usual_range, z: p.z, score: p.score, arrow: p.arrow, tint: p.tint });
  return { score: r.score, band: r.band, status: r.status, reason: r.reason, nights_of_history: r.nights_of_history, nights_needed: r.nights_needed,
    parts: { sleep: r.parts.sleep, hrv: heart(r.parts.hrv), resting_hr: heart(r.parts.resting_hr) } };
}

/** The night ending on `day` and whether the digest may show (night ended ≥ 30 min before `at`). */
function digestState(day: string, at: number) {
  const n = one<{ sleep_end: string | null }>("SELECT sleep_end FROM sleep_nights WHERE day=? AND sleep_end IS NOT NULL ORDER BY sleep_end LIMIT 1", day);
  const end = n?.sleep_end ?? null;
  return { available: !!end && Date.parse(end) <= at - DIGEST_SETTLE_MIN * MIN, night_ended_at: end };
}

function strengthOn(day: string) {
  const off = ownerOffsetMin(Date.parse(`${day}T12:00:00Z`));
  return all<{ id: string; title: string | null; started_at: number; tz_offset_min: number; working: number }>(`SELECT s.id, s.title, s.started_at, s.tz_offset_min,
    (SELECT COUNT(*) FROM sets x WHERE x.session_id=s.id AND x.deleted_at IS NULL AND x.kind!='warmup') working FROM sessions s
    WHERE s.deleted_at IS NULL AND s.started_at BETWEEN ? AND ? AND EXISTS (SELECT 1 FROM sets x WHERE x.session_id=s.id AND x.deleted_at IS NULL)
    ORDER BY s.started_at`, localMs(day, 0, off) - 14 * 60 * MIN, localMs(day, 1440, off) + 14 * 60 * MIN)
    .filter((s) => localDay(s.started_at, s.tz_offset_min) === day);
}

function pulse(day: string, at: number, bedByMin: number) {
  const off = ownerOffsetMin(at);
  const wake = one<{ sleep_end: string | null }>("SELECT sleep_end FROM sleep_nights WHERE day=? AND sleep_end IS NOT NULL ORDER BY sleep_end LIMIT 1", day)?.sleep_end ?? null;
  const start = wake ? Date.parse(wake) : localMs(day, 6 * 60, off);
  let end = localMs(day, bedByMin, off);
  if (end <= start) end += 1440 * MIN;
  const events: { at: number; kind: string }[] = [];
  if (wake) events.push({ at: start, kind: "wake" });
  for (const w of all<{ at: number }>("SELECT measured_at at FROM weight_entries WHERE day=? AND deleted_at IS NULL", day)) events.push({ at: w.at, kind: "weigh_in" });
  for (const w of all<{ at: number }>(`SELECT s.start_ms at FROM hk_samples s JOIN hk_types t ON t.id=s.type_id
    WHERE t.metric='weight_kg' AND s.day=? AND s.deleted_at IS NULL`, day)) events.push({ at: w.at, kind: "weigh_in" });
  for (const m of mealTimes(day)) events.push({ at: m.at, kind: "meal" });
  for (const s of strengthOn(day)) events.push({ at: s.started_at, kind: "workout" });
  const seen = new Set<string>();
  return {
    window: { start: isoAt(start, off), end: isoAt(end, off) }, now: isoAt(at, off),
    events: events.filter((e) => e.at <= at).sort((a, b) => a.at - b.at)
      .filter((e) => { const k = `${e.kind}|${Math.round(e.at / MIN)}`; if (seen.has(k)) return false; seen.add(k); return true; })
      .map((e) => ({ at: isoAt(e.at, off), kind: e.kind })),
  };
}

/** Steps and active energy against the usual by now (11 §6); a past day is judged on its whole day. */
function activity(day: string, at: number, stepsTarget: number) {
  const off = ownerOffsetMin(at), t = todayOf(at);
  const mins = day < t ? 1440 : minuteOfDay(at, off);
  const from = addDays(day, -28), to = addDays(day, -1);
  const curves = [...featuresRange(from, to).values()];
  const one_ = (key: "steps" | "active_kcal", curve: "steps_curve" | "kcal_curve", kind: "steps" | "kcal") => {
    const value = daily(key, day, day).get(day) ?? null;
    const expected = expectedNow(usualTotal([...daily(key, from, to).values()]), usualFractionNow(curves.map((f) => f[curve]).filter((c): c is number[] => !!c), mins));
    return { value: value === null ? null : Math.round(value), expected, pace: pace(value, expected, kind) };
  };
  const steps = one_("steps", "steps_curve", "steps"), kcal = one_("active_kcal", "kcal_curve", "kcal");
  return { steps: steps.value, steps_target: stepsTarget, steps_expected_now: steps.expected, steps_pace: steps.pace,
    active_kcal: kcal.value, active_kcal_expected_now: kcal.expected, active_kcal_pace: kcal.pace };
}

/** Everything Today and the digest share for `day` at `at`. */
function assemble(day: string, at: number) {
  const off = ownerOffsetMin(at), nowMin = minuteOfDay(at, off);
  const scores = scoresFor(day, at), targets = effectiveTargets(at), night = tonightFor(day);
  const sums = daySums(day), slot: Slot = nextSlot(day, nowMin);
  const kcalLeft = Math.round(targets.kcal - sums.kcal);
  const training = trainingState(at);
  const sessions = strengthOn(day), last = sessions.at(-1);
  const rec = recoveryView(scores);
  const v = verdict({
    recovery: { band: rec.band as Verdict["band"], score: rec.score, reason: rec.reason },
    hints: { hrv: { arrow: rec.parts.hrv.arrow as never, tint: rec.parts.hrv.tint as never }, resting_hr: { arrow: rec.parts.resting_hr.arrow as never, tint: rec.parts.resting_hr.tint as never } },
    // No splits yet: a loaded muscle is a fact worth saying; otherwise anything goes.
    trainable: training.splits.length ? training.splits.some((s) => s.ready) : training.loaded_label === null, strength_today: last ? { title: last.title ?? "Workout", sets: sessions.reduce((n, s) => n + s.working, 0) } : null,
    kcal_left: kcalLeft, next_slot: slot, now_min: day === todayOf(at) ? nowMin : 12 * 60, bed_by_min: day === todayOf(at) ? night.bed_by_min : null,
  });
  return { off, scores, rec, targets, night, sums, slot, kcalLeft, training, v };
}

const verdictView = (v: Verdict) => ({ band: v.band, label: v.label, headline: v.headline, reason: v.reason, action: v.action });

export function todayBody(day: string, at = Date.now()) {
  const a = assemble(day, at);
  return {
    day, generated_at: isoAt(at, a.off),
    verdict: verdictView(a.v),
    recovery: a.rec,
    fuel: { kcal_target: a.targets.kcal, kcal_eaten: Math.round(a.sums.kcal), kcal_left: a.kcalLeft,
      protein_target_g: a.targets.protein_g, protein_g: Math.round(a.sums.protein_g), next_slot: a.slot, next_label: `LOG ${a.slot.toUpperCase()}` },
    activity: activity(day, at, a.targets.steps),
    training: { heat: a.training.heat, fresh_label: a.training.fresh_label, loaded_label: a.training.loaded_label,
      due: null, splits: a.training.splits.map(({ muscles: _m, ...r }) => r),
      trained_today: a.training.trained_today },
    pulse: pulse(day, at, a.night.bed_by_min),
    digest: digestState(day, at),
    freshness: freshnessBlock(at),
  };
}

const DOW = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"], MON = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"];
export const dateLabel = (day: string) => { const d = new Date(`${day}T00:00:00Z`); return `${DOW[d.getUTCDay()]} ${d.getUTCDate()} ${MON[d.getUTCMonth()]}`; };
const signedMin = (m: number) => `${m >= 0 ? "+" : "−"}${Math.abs(Math.round(m))}M`;

export function digestBody(day: string, at = Date.now()) {
  const a = assemble(day, at), st = digestState(day, at), sleep = a.scores.sleep;
  const part = (k: string) => sleep?.parts.find((p) => p.key === k);
  const night = nights(day, day)[0] ?? null, wakeups = featuresRange(day, day).get(day)?.wakeups ?? null;
  const usual = baseline("sleep_h", day) as { raw?: { usual: number } };
  const tint = (k: string) => ((part(k)?.score ?? 100) < 70 ? "watch" : null);
  const cons = part("consistency"), eff = part("efficiency"), wake = part("wakeups");
  const yesterday = addDays(day, -1), ys = strengthOn(yesterday).at(-1);
  const yw = ys ? null : one<{ id: string; name: string }>("SELECT id,name FROM hk_workouts WHERE day=? ORDER BY start_ms DESC LIMIT 1", yesterday);
  const plan: { kind: string; title: string; reason: string; primary: boolean }[] = [];
  const action = a.v.action;
  if (action.kind === "start_workout") {
    const ready = a.training.splits.filter((s) => s.ready).map((s) => s.name.toUpperCase());
    plan.push({ kind: "train", title: action.intensity === "light" ? "Train light" : "Train", reason: ready.length ? `${ready.join(" · ")} READY` : "PICK AS YOU GO", primary: true });
  } else if (action.kind === "bed_reminder") plan.push({ kind: "sleep", title: `Bed by ${a.night.bed_by}`, reason: a.night.label, primary: true });
  plan.push({ kind: "eat", title: `Eat ${fmt(a.targets.kcal)} kcal`, reason: `${a.targets.protein_g} G PROTEIN`, primary: false });
  const usualSteps = a.targets.steps28.length >= 7 ? stepsTarget(a.targets.steps28) : null;
  plan.push({ kind: "walk", title: `Walk ${fmt(a.targets.steps)}`, reason: usualSteps === a.targets.steps ? "YOUR USUAL" : "YOUR TARGET", primary: false });
  if (!plan.some((p) => p.primary)) plan[0].primary = true;
  const hour = Math.floor(minuteOfDay(at, a.off) / 60);
  return {
    day, available: st.available, night_ended_at: st.night_ended_at, date_label: dateLabel(day),
    greeting: hour < 12 ? "GOOD MORNING" : hour < 17 ? "GOOD AFTERNOON" : "GOOD EVENING",
    headline: digestHeadline(sleep?.band ?? null, a.rec.band as never),
    sleep: sleep && night ? {
      score: sleep.score, band: sleep.band,
      rows: [
        { key: "duration", label: "DURATION", value: hmLabel(night.asleep_h), delta: usual.raw ? signedMin((night.asleep_h - usual.raw.usual) * 60) : null,
          tint: tint("duration") ?? (night.asleep_h >= sleep.need_h ? "good" : null) },
        { key: "bedtime", label: "BEDTIME", value: night.sleep_start ? night.sleep_start.slice(11, 16) : null,
          delta: cons?.delta_min == null ? null : Math.abs(cons.delta_min) < 5 ? "ON TIME" : `${Math.abs(Math.round(cons.delta_min))}M ${cons.delta_min > 0 ? "LATE" : "EARLY"}`, tint: tint("consistency") },
        { key: "efficiency", label: "EFFICIENCY", value: eff?.score == null ? null : eff.detail.replace(/ ASLEEP$/, ""), tint: tint("efficiency") },
        { key: "wakeups", label: "WAKE-UPS", value: wakeups === null ? null : String(wakeups), tint: tint("wakeups") },
      ],
    } : null,
    recovery: night ? { score: a.rec.score, band: a.rec.band, label: a.scores.recovery.label,
      hrv: { value: a.rec.parts.hrv.value, arrow: a.rec.parts.hrv.arrow, tint: a.rec.parts.hrv.tint },
      resting_hr: { value: a.rec.parts.resting_hr.value, arrow: a.rec.parts.resting_hr.arrow, tint: a.rec.parts.resting_hr.tint } } : null,
    yesterday: { day: yesterday, steps: roundOrNull(daily("steps", yesterday, yesterday).get(yesterday)), active_kcal: roundOrNull(daily("active_kcal", yesterday, yesterday).get(yesterday)),
      workout: ys ? { id: ys.id, title: ys.title ?? "Workout", kind: "strength" } : yw ? { id: yw.id, title: yw.name, kind: "cardio" } : null },
    plan: plan.slice(0, 3),
    pulse: pulse(day, at, a.night.bed_by_min),
    freshness: freshnessBlock(at),
  };
}
const roundOrNull = (v: number | undefined) => (v === undefined ? null : Math.round(v));
