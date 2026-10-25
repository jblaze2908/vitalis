// Validate the envelope separately: one malformed object must not discard its neighbours.
import { z } from "zod";

const text = z.string().min(1);
export const stamp = z.iso.datetime({ offset: true }).refine((s) => Number.isFinite(Date.parse(s)), "Invalid timestamp");
const zones = new Map<string, boolean>();
export const zone = z.string().refine((tz) => {
  const known = zones.get(tz); if (known !== undefined) return known;
  let valid: boolean;
  try { new Intl.DateTimeFormat("en", { timeZone: tz }); valid = true; } catch { valid = false; }
  if (zones.size >= 512) zones.delete(zones.keys().next().value!);
  zones.set(tz, valid); return valid;
}, "Invalid time zone");
const object = z.record(z.string(), z.unknown());
const interval = { start: stamp, end: stamp };
const ordered = (s: { start: string; end: string }) => Date.parse(s.end) >= Date.parse(s.start);
const point = z.tuple([stamp, stamp, z.number()]).refine(([s, e]) => Date.parse(e) >= Date.parse(s), "Series end precedes start");
const base = {
  uuid: text, type: text, ...interval, tz: zone.nullish(),
  source: z.object({ name: text, bundle_id: text, version: z.string().nullish(), product_type: z.string().nullish(), os_version: z.union([z.string(), object]).nullish() }).passthrough(),
  device: object.nullish(), metadata: object.nullish(),
};
const event = z.object({ type: z.union([z.string(), z.int()]), ...interval, metadata: object.nullish() }).passthrough().refine(ordered, "Event end precedes start");
const stat = z.object({ sum: z.number().nullish(), min: z.number().nullish(), avg: z.number().nullish(), max: z.number().nullish(), unit: text }).passthrough();
export const sampleSchema = z.discriminatedUnion("kind", [
  z.object({ ...base, kind: z.literal("quantity"), value: z.number(), unit: text, series: z.array(point).optional() }).passthrough(),
  // HealthKit values newer than the exporter's label table arrive with a null label; the int value is what counts.
  z.object({ ...base, kind: z.literal("category"), value: z.int(), value_label: text.nullable() }).passthrough(),
  z.object({ ...base, kind: z.literal("workout"), activity_type: z.int(), activity_name: text, duration_s: z.number().nonnegative(),
    events: z.array(event), activities: z.array(z.object({ uuid: text, activity_type: z.int(), activity_name: text, ...interval,
      metadata: object.nullish(), statistics: z.record(z.string(), stat) }).passthrough().refine(ordered, "Activity end precedes start")),
    statistics: z.record(z.string(), stat) }).passthrough(),
  z.object({ ...base, kind: z.literal("route"), workout_uuid: text,
    points: z.array(z.tuple([stamp, z.number().min(-90).max(90), z.number().min(-180).max(180), z.number(), z.number(), z.number(), z.number(), z.number()])) }).passthrough(),
  z.object({ ...base, kind: z.literal("heartbeat"), beats: z.array(z.tuple([z.number().nonnegative(), z.boolean()])) }).passthrough(),
  z.object({ ...base, kind: z.literal("ecg"), classification: z.union([z.string(), z.int()]), symptoms_status: z.union([z.string(), z.int()]),
    avg_hr: z.number().nullable(), sampling_hz: z.number().positive(), voltages_uv: z.array(z.number()) }).passthrough(),
  z.object({ ...base, kind: z.literal("correlation"), objects: z.array(text) }).passthrough(),
  z.object({ ...base, kind: z.literal("state_of_mind"), state_kind: z.union([z.string(), z.int()]), valence: z.number(), labels: z.array(z.int()), associations: z.array(z.int()) }).passthrough(),
  z.object({ ...base, kind: z.literal("other"), payload: z.unknown().refine((p) => p !== undefined, "Missing payload") }).passthrough(),
]).refine(ordered, "Sample end precedes start");
export const deletionSchema = z.object({ uuid: text, type: text }).passthrough();
export const dailySchema = stat.extend({ type: text, day: z.iso.date(), tz: zone }).refine(
  (s) => [s.sum, s.min, s.avg, s.max].some((v) => v != null), "Daily statistic has no values");
export const envelopeSchema = z.object({ schema: z.literal(1), batch_id: text,
  client: z.object({ install_id: text, app_version: text, os: text, model: text }).passthrough(),
  upserts: z.array(z.unknown()), deletions: z.array(z.unknown()), daily_stats: z.array(z.unknown()),
}).passthrough();
export type Sample = z.infer<typeof sampleSchema>;
export type DailyStat = z.infer<typeof dailySchema>;
