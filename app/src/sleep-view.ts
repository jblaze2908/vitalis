// GET /v2/sleep and /v2/sleep/week bodies (spec 10 §5). Stages are shown one tap down only; they never enter a score.
import { scoresFor, tonightFor } from "./derived.js";
import { freshnessBlock } from "./health.js";
import { roundHalfAway } from "./scoring-config.js";
import { baseline, naps, nights, type Night } from "./stats.js";
import { all } from "./db.js";
import { addDays, eveningMinutes, fromEveningMinutes, today } from "./time.js";
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
      asleep_h: roundHalfAway(n.asleep_h, 2), asleep_label: hmLabel(n.asleep_h), source: n.source, segments: segments(n) },
    score: s.score, band: s.band, label: s.label, status: s.score === null ? "missing" : "ok",
    duration: { asleep_label: hmLabel(n.asleep_h), vs_usual_min: vs, vs_usual_label: vs === null ? null : `${vs >= 0 ? "+" : "−"}${Math.abs(vs)}M`,
      need_h: s.need_h, need_label: hmLabel(s.need_h), need_basis: s.need_basis, nap_credit_h: roundHalfAway(s.nap_credit_h ?? 0, 2) },
    parts: s.parts.map((p) => ({ key: p.key, label: p.label, detail: p.detail, score: p.score, flagged: p.flagged, weight: p.weight })),
    stages: { core_h: round2(n.core_h), deep_h: round2(n.deep_h), rem_h: round2(n.rem_h), awake_h: round2(n.awake_h), note: STAGE_NOTE },
    tonight: tonightView(day), freshness: freshnessBlock(at),
  };
}
const STAGE: Record<number, string> = { 1: "asleep", 2: "awake", 3: "core", 4: "deep", 5: "rem" };

/**
 * The night's stages in time order, joined where one stage runs on, for the Sleep tab's stage chart. Unspecified sleep is
 * dropped when the source also staged it. Null for nights from Health Auto Export summaries, which carry no samples.
 * Per call: one indexed read of the night's members (a few hundred rows).
 */
function segments(n: Night) {
  if (!n.sleep_start || !n.sleep_end) return null;
  const from = Date.parse(n.sleep_start), to = Date.parse(n.sleep_end);
  const rows = all<{ s: string; e: string; sm: number; em: number; v: number }>(`SELECT r.start_iso s,r.end_iso e,r.start_ms sm,r.end_ms em,r.category_value v
    FROM hk_sleep_members m JOIN hk_raw r USING(uuid) WHERE m.day=? AND m.source=? AND r.deleted_at IS NULL AND r.start_ms<? AND r.end_ms>? ORDER BY r.start_ms`,
    n.day, n.source, to, from).filter((r) => STAGE[r.v]);
  if (!rows.length) return null;
  const staged = rows.some((r) => r.v >= 3);
  const out: { stage: string; start: string; end: string; em: number }[] = [];
  for (const r of rows) {
    if (staged && r.v === 1) continue;
    const prev = out.at(-1);
    if (prev && prev.stage === STAGE[r.v] && r.sm <= prev.em + 60_000) { if (r.em > prev.em) { prev.end = r.e; prev.em = r.em; } continue; }
    out.push({ stage: STAGE[r.v], start: r.s, end: r.e, em: r.em });
  }
  return out.map(({ em: _e, ...x }) => x);
}

const mean = (xs: number[]) => xs.reduce((a, b) => a + b, 0) / xs.length;
const wakeMin = (iso: string) => Number(iso.slice(11, 13)) * 60 + Number(iso.slice(14, 16));
const clock = (m: number) => `${String(Math.floor(m / 60) % 24).padStart(2, "0")}:${String(Math.round(m) % 60).padStart(2, "0")}`;

/** Per-night rows plus averages over [from, to] (to ≤ today): what the Week and Month views draw. */
function nightsBetween(from: string, to: string, at: number) {
  const ns = new Map(nights(from, to).map((n) => [n.day, n])), napList = naps(from, to), days: string[] = [];
  for (let d = from; d <= to; d = addDays(d, 1)) days.push(d);
  const list = days.map((day) => {
    const n = ns.get(day), napH = napList.filter((x) => x.day === day && (!n || x.source === n.source)).reduce((h, x) => h + x.asleep_h, 0);
    return { day, score: n ? scoresFor(day, at).sleep?.score ?? null : null, asleep_h: n ? roundHalfAway(n.asleep_h, 2) : null,
      sleep_start: n?.sleep_start ?? null, sleep_end: n?.sleep_end ?? null, nap_h: roundHalfAway(napH, 2) };
  });
  const had = list.filter((x) => x.asleep_h !== null), scores = list.map((x) => x.score).filter((v): v is number => v !== null);
  const beds = had.filter((x) => x.sleep_start).map((x) => eveningMinutes(x.sleep_start!)), wakes = had.filter((x) => x.sleep_end).map((x) => wakeMin(x.sleep_end!));
  return { list, avg: {
    asleep_h: had.length ? roundHalfAway(mean(had.map((x) => x.asleep_h!)), 2) : null,
    score: scores.length ? roundHalfAway(mean(scores)) : null,
    bedtime: beds.length ? fromEveningMinutes(mean(beds)) : null, wake: wakes.length ? clock(mean(wakes)) : null,
    nap_h: roundHalfAway(list.reduce((h, x) => h + x.nap_h, 0), 2), nights: had.length, missing: list.length - had.length } };
}

/** GET /v2/sleep/month?month=YYYY-MM: every night of the month so far, averages, and last month's average score. */
export function sleepMonth(month: string, at = Date.now()) {
  const t = today(at), first = `${month}-01`;
  const last = addDays(`${nextMonth(month)}-01`, -1), to = last < t ? last : t;
  const prevFirst = `${prevMonth(month)}-01`, prev = nightsBetween(prevFirst, addDays(first, -1), at);
  const cur = first <= t ? nightsBetween(first, to, at) : { list: [], avg: null };
  return { month, days: cur.list, avg: cur.avg, prev_avg_score: prev.avg.score, prev_month: prevMonth(month),
    next_month: `${nextMonth(month)}-01` <= t ? nextMonth(month) : null, freshness: freshnessBlock(at) };
}
const shiftMonth = (month: string, n: number) => { const d = new Date(`${month}-01T00:00:00Z`); d.setUTCMonth(d.getUTCMonth() + n); return d.toISOString().slice(0, 7); };
const nextMonth = (m: string) => shiftMonth(m, 1), prevMonth = (m: string) => shiftMonth(m, -1);

const round2 = (v: number | null) => (v === null ? null : roundHalfAway(v, 2));

export function sleepWeek(end: string, at = Date.now()) {
  const from = addDays(end, -6), cur = nightsBetween(from, end, at), prev = nightsBetween(addDays(from, -7), addDays(end, -7), at);
  const beds = cur.list.filter((n) => n.sleep_start).map((n) => eveningMinutes(n.sleep_start!));
  const spread = beds.length ? roundHalfAway(mean(beds.map((b) => Math.abs(b - mean(beds))))) : null, avg = cur.avg.score;
  return { end, nights: cur.list, avg_score: avg, bedtime_spread_min: spread, avg: cur.avg, prev_avg_score: prev.avg.score,
    label: [avg !== null ? `AVG ${avg}` : null, spread !== null ? `BED ± ${spread}M` : null].filter(Boolean).join(" · ") || null,
    freshness: freshnessBlock(at) };
}
