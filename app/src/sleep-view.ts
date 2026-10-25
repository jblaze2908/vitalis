// GET /v2/sleep and /v2/sleep/week bodies (spec 10 §5). Stages are shown one tap down only; they never enter a score.
import { scoresFor, tonightFor } from "./derived.js";
import { freshnessBlock } from "./health.js";
import { roundHalfAway } from "./scoring-config.js";
import { baseline, naps, nights } from "./stats.js";
import { addDays, eveningMinutes, today } from "./time.js";
import { hmLabel } from "./today.js";

const STAGE_NOTE = "Stages are estimates and are not part of the score.";

const tonightView = (day: string) => {
  const t = tonightFor(day);
  return { bed_by: t.bed_by, wake_time: t.wake_time, need_h: t.need_h, label: t.label };
};

export function sleepDay(day: string, at = Date.now()) {
  const t = today(at), n = nights(day, day)[0] ?? null;
  // Naps from the night's source only, so a second watch can't double them; with no night, every nap that day.
  const dayNaps = naps(day, day).filter((x) => !n || x.source === n.source).map((x) => ({ start: x.start, end: x.end,
    asleep_h: roundHalfAway(x.asleep_h, 2), asleep_label: hmLabel(x.asleep_h) }));
  const napH = dayNaps.reduce((h, x) => h + x.asleep_h, 0);
  const base = { day, has_night: !!n, prev_day: addDays(day, -1), next_day: day >= t ? null : addDays(day, 1), naps: dayNaps,
    total_h: roundHalfAway((n?.asleep_h ?? 0) + napH, 2), total_label: hmLabel((n?.asleep_h ?? 0) + napH) };
  if (!n) return { ...base, night: null, score: null, band: null, label: null, status: "missing", duration: null, parts: null, stages: null,
    tonight: tonightView(day), freshness: freshnessBlock(at) };
  const s = scoresFor(day, at).sleep!;
  const usual = baseline("sleep_h", day) as { raw?: { usual: number } };
  const vs = usual.raw ? Math.round((n.asleep_h - usual.raw.usual) * 60) : null;
  return {
    ...base,
    night: { sleep_start: n.sleep_start, sleep_end: n.sleep_end, in_bed_start: n.in_bed_start, in_bed_end: n.in_bed_end,
      asleep_h: roundHalfAway(n.asleep_h, 2), asleep_label: hmLabel(n.asleep_h), source: n.source },
    score: s.score, band: s.band, label: s.label, status: s.score === null ? "missing" : "ok",
    duration: { asleep_label: hmLabel(n.asleep_h), vs_usual_min: vs, vs_usual_label: vs === null ? null : `${vs >= 0 ? "+" : "−"}${Math.abs(vs)}M`,
      need_h: s.need_h, need_label: hmLabel(s.need_h), need_basis: s.need_basis, nap_credit_h: roundHalfAway(s.nap_credit_h ?? 0, 2) },
    parts: s.parts.map((p) => ({ key: p.key, label: p.label, detail: p.detail, score: p.score, flagged: p.flagged, weight: p.weight })),
    stages: { core_h: round2(n.core_h), deep_h: round2(n.deep_h), rem_h: round2(n.rem_h), awake_h: round2(n.awake_h), note: STAGE_NOTE },
    tonight: tonightView(day), freshness: freshnessBlock(at),
  };
}
const round2 = (v: number | null) => (v === null ? null : roundHalfAway(v, 2));

export function sleepWeek(end: string, at = Date.now()) {
  const from = addDays(end, -6), ns = new Map(nights(from, end).map((n) => [n.day, n])), napList = naps(from, end);
  const list = Array.from({ length: 7 }, (_, i) => addDays(from, i)).map((day) => {
    const n = ns.get(day), napH = napList.filter((x) => x.day === day && (!n || x.source === n.source)).reduce((h, x) => h + x.asleep_h, 0);
    return { day, score: n ? scoresFor(day, at).sleep?.score ?? null : null, asleep_h: n ? roundHalfAway(n.asleep_h, 2) : null,
      sleep_start: n?.sleep_start ?? null, sleep_end: n?.sleep_end ?? null, nap_h: roundHalfAway(napH, 2) };
  });
  const scores = list.map((x) => x.score).filter((v): v is number => v !== null);
  const beds = [...ns.values()].filter((n) => n.sleep_start).map((n) => eveningMinutes(n.sleep_start!));
  const mean = (xs: number[]) => xs.reduce((a, b) => a + b, 0) / xs.length;
  const avg = scores.length ? roundHalfAway(mean(scores)) : null;
  const spread = beds.length ? roundHalfAway(mean(beds.map((b) => Math.abs(b - mean(beds))))) : null;
  return { end, nights: list, avg_score: avg, bedtime_spread_min: spread,
    label: [avg !== null ? `AVG ${avg}` : null, spread !== null ? `BED ± ${spread}M` : null].filter(Boolean).join(" · ") || null,
    freshness: freshnessBlock(at) };
}
