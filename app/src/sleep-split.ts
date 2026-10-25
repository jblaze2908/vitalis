// Turns raw Health sleep samples into nights and naps. Pure: no I/O, so every scenario is a unit test.
import { dayAt } from "./v2-metrics.js";

/** HKCategoryValueSleepAnalysis: 0 inBed, 1 asleepUnspecified, 2 awake, 3 core, 4 deep, 5 REM. */
export type SleepSample = { uuid: string; start: number; end: number; startIso: string; endIso: string; tz: string | null; value: number };
export type SleepBlock = {
  day: string; kind: "night" | "nap"; start: number; end: number; startIso: string; endIso: string;
  inBedStart: string | null; inBedEnd: string | null; asleep_h: number; core_h: number | null; deep_h: number | null; rem_h: number | null;
  awake_h: number | null; wakeups: number | null; members: string[];
};

const MIN = 60_000, HOUR = 60 * MIN;
// Design defaults, chosen against Fitbit (splits on > 1 h awake), Oura (naps ≥ 15 min, sleep after 18:00 counts toward the
// next morning) and GGIR (longest block is the main sleep). 2 h keeps an hour awake at 03:00 inside one night.
export const SPLIT = { GAP_MS: 2 * HOUR, MIN_BLOCK_MS: 15 * MIN, DAY_SHIFT_MS: 6 * HOUR, WAKEUP_MIN_MS: MIN };

const ASLEEP = new Set([1, 3, 4, 5]);
type Span = { start: number; end: number };

function union(spans: Span[]): Span[] {
  const out: Span[] = [];
  for (const s of [...spans].sort((a, b) => a.start - b.start)) {
    const prev = out.at(-1);
    if (prev && s.start <= prev.end) prev.end = Math.max(prev.end, s.end);
    else out.push({ ...s });
  }
  return out;
}
/** Local start hour in [18, 24) or [0, 10); the ISO carries the wall clock of the sample's own offset. */
const nightStart = (iso: string) => { const h = Number(iso.slice(11, 13)); return h >= 18 || h < 10; };
const total = (spans: Span[]) => spans.reduce((n, s) => n + s.end - s.start, 0);

/**
 * Blocks: asleep time joined across gaps of ≤ 2 h. Sleep day: the local date 6 h after the block starts, so sleep
 * that begins at 18:00 or later belongs to the next morning. Per sleep day one block is the night (see below);
 * every other block is a nap. Blocks under 15 min asleep are dropped as noise. One source's samples per call.
 */
export function sleepBlocks(samples: SleepSample[]): SleepBlock[] {
  const asleep = samples.filter((s) => ASLEEP.has(s.value) && s.end > s.start);
  const segments = union(asleep);
  const groups: Span[][] = [];
  for (const seg of segments) {
    const g = groups.at(-1);
    if (g && seg.start - g.at(-1)!.end <= SPLIT.GAP_MS) g.push(seg);
    else groups.push([seg]);
  }
  const blocks: SleepBlock[] = [];
  for (const g of groups) {
    const start = g[0].start, end = g.at(-1)!.end, asleepMs = total(g);
    if (asleepMs < SPLIT.MIN_BLOCK_MS) continue;
    const inside = samples.filter((s) => s.end > start && s.start < end);
    const first = asleep.find((s) => s.start === start)!, last = asleep.filter((s) => s.end === end).at(-1)!;
    const hours = (value: number) => total(union(inside.filter((s) => s.value === value).map((s) => ({ start: Math.max(s.start, start), end: Math.min(s.end, end) })))) / HOUR;
    const staged = inside.some((s) => s.value >= 3 && s.value <= 5), hasAwake = inside.some((s) => s.value === 2);
    // Wake-ups: awake samples plus unrecorded gaps between sleep, merged, ≥ 1 min; unknown when the source records neither stages nor awake.
    const awakeSpans = union([...inside.filter((s) => s.value === 2).map((s) => ({ start: Math.max(s.start, start), end: Math.min(s.end, end) })),
      ...g.slice(1).map((seg, i) => ({ start: g[i].end, end: seg.start }))]);
    const bed = samples.filter((s) => s.value === 0 && s.end > start && s.start < end);
    const bedFirst = bed.reduce<SleepSample | null>((a, b) => (!a || b.start < a.start ? b : a), null);
    const bedLast = bed.reduce<SleepSample | null>((a, b) => (!a || b.end > a.end ? b : a), null);
    blocks.push({
      day: dayAt(start + SPLIT.DAY_SHIFT_MS, first.startIso, first.tz), kind: "nap", start, end, startIso: first.startIso, endIso: last.endIso,
      inBedStart: bedFirst?.startIso ?? null, inBedEnd: bedLast?.endIso ?? null, asleep_h: asleepMs / HOUR,
      core_h: staged ? hours(3) : null, deep_h: staged ? hours(4) : null, rem_h: staged ? hours(5) : null,
      awake_h: hasAwake ? hours(2) : null,
      wakeups: staged || hasAwake ? awakeSpans.filter((w) => w.end - w.start >= SPLIT.WAKEUP_MIN_MS).length : null,
      members: inside.map((s) => s.uuid),
    });
  }
  // The night is the longest block that began between 18:00 and 10:00; only a day with no such block falls back to its longest.
  // That keeps a long afternoon sleep from replacing the night, the failure Garmin users report.
  const rank = (b: SleepBlock) => [nightStart(b.startIso) ? 1 : 0, b.asleep_h];
  const main = new Map<string, SleepBlock>();
  for (const b of blocks) {
    const m = main.get(b.day);
    if (!m) { main.set(b.day, b); continue; }
    const [bw, bh] = rank(b), [mw, mh] = rank(m);
    if (bw > mw || (bw === mw && bh > mh)) main.set(b.day, b);
  }
  for (const b of main.values()) b.kind = "night";
  return blocks;
}
