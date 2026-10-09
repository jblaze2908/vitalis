// Dates as Health Auto Export sends them ("2026-10-05 22:58:32 +0530", a bare "2026-10-06", or ISO 8601), kept in the
// wall-clock zone they were recorded in: a day is the phone's local day, never the server's.
import { TZ } from "./config.js";

export type Stamp = { iso: string; ms: number; offsetMin: number; day: string };

const RE = /^(\d{4}-\d{2}-\d{2})(?:[ T](\d{1,2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?\s*(?:(AM|PM)\s*)?(Z|[+-]\d{2}:?\d{2})?)?$/i;

export function parseStamp(raw: unknown): Stamp | null {
  if (typeof raw !== "string") return null;
  // iOS 12-hour locales put a narrow no-break space before AM/PM.
  const m = RE.exec(raw.trim().replace(/[  ]/g, " "));
  if (!m) return null;
  const [, day, hh = "0", mi = "0", ss = "0", ampm, zone] = m;
  let h = Number(hh);
  if (ampm) h = (h % 12) + (ampm.toUpperCase() === "PM" ? 12 : 0);
  const offsetMin = zone ? zoneMinutes(zone) : 0;
  const ms = Date.UTC(+day.slice(0, 4), +day.slice(5, 7) - 1, +day.slice(8, 10), h, +mi, +ss) - offsetMin * 60_000;
  if (Number.isNaN(ms)) return null;
  return { iso: isoAt(ms, offsetMin), ms, offsetMin, day };
}

function zoneMinutes(z: string) {
  if (z.toUpperCase() === "Z") return 0;
  const sign = z[0] === "-" ? -1 : 1, d = z.slice(1).replace(":", "");
  return sign * (Number(d.slice(0, 2)) * 60 + Number(d.slice(2, 4)));
}

const pad = (n: number) => String(Math.abs(n)).padStart(2, "0");
export function isoAt(ms: number, offsetMin: number) {
  const d = new Date(ms + offsetMin * 60_000).toISOString().slice(0, 19);
  return `${d}${offsetMin < 0 ? "-" : "+"}${pad(Math.trunc(offsetMin / 60))}:${pad(offsetMin % 60)}`;
}
export const localDay = (ms: number, offsetMin: number) => new Date(ms + offsetMin * 60_000).toISOString().slice(0, 10);
export const clock = (iso: string | null | undefined) => (iso ? iso.slice(11, 16) : null);

/** Minutes past 18:00 local, so bedtimes either side of midnight average and compare correctly. */
export function eveningMinutes(iso: string) {
  const m = Number(iso.slice(11, 13)) * 60 + Number(iso.slice(14, 16));
  return (m - 18 * 60 + 1440) % 1440;
}
export function fromEveningMinutes(m: number) {
  const t = (Math.round(m) + 18 * 60) % 1440;
  return `${pad(Math.floor(t / 60))}:${pad(t % 60)}`;
}

export function addDays(day: string, n: number) {
  const d = new Date(`${day}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}
export const daysBetween = (a: string, b: string) => Math.round((Date.parse(`${b}T00:00:00Z`) - Date.parse(`${a}T00:00:00Z`)) / 86_400_000);

/** The owner's current offset in minutes, from VITALIS_TZ. */
export function ownerOffsetMin(at = Date.now()) {
  const parts = new Intl.DateTimeFormat("en-US", { timeZone: TZ, timeZoneName: "longOffset" }).formatToParts(at);
  const name = parts.find((p) => p.type === "timeZoneName")?.value ?? "GMT";
  const m = /GMT([+-]\d{2}):?(\d{2})?/.exec(name);
  return m ? zoneMinutes(`${m[1]}${m[2] ?? "00"}`) : 0;
}
export const today = (at = Date.now()) => localDay(at, ownerOffsetMin(at));

export const DAY_RE = /^\d{4}-\d{2}-\d{2}$/;
