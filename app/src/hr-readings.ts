// Raw heart-rate readings for a time window. Kept apart from heart.ts so the ingest worker can use it without the read-side imports.
import { all, one } from "./db.js";
import { HR_TYPE, nativeValue } from "./v2-metrics.js";
import { quantitySeries } from "./v2-storage.js";

export type Reading = { ms: number; bpm: number; source: string; bundle: string };
type Row = { start_ms: number; end_ms: number; value: number | null; unit: string; source: string; bundle: string; data: Uint8Array | null };

/** Readings that start and end inside [startMs, endMs], oldest first: two indexed range seeks, plain samples then packed series. */
export function heartReadings(startMs: number, endMs: number): Reading[] {
  const type = one<{ id: number; duration_ms: number }>("SELECT id,duration_ms FROM hk_types WHERE identifier=?", HR_TYPE);
  if (!type) return [];
  const rows = all<Row>(`SELECT s.start_ms,s.end_ms,s.value,s.unit,COALESCE(src.name,'') source,COALESCE(src.bundle,'') bundle,b.data
    FROM hk_samples s LEFT JOIN hk_blobs b ON b.sample_id=s.id LEFT JOIN hk_sources src ON src.id=s.source_id
    WHERE s.type_id=? AND s.kind=0 AND s.deleted_at IS NULL AND b.start_ms IS NULL AND s.end_ms BETWEEN ? AND ? AND s.start_ms>=?
    UNION ALL SELECT s.start_ms,s.end_ms,s.value,s.unit,COALESCE(src.name,''),COALESCE(src.bundle,''),b.data
    FROM hk_blobs b JOIN hk_samples s ON s.id=b.sample_id LEFT JOIN hk_sources src ON src.id=s.source_id
    WHERE s.type_id=? AND s.kind=0 AND s.deleted_at IS NULL AND b.end_ms BETWEEN ? AND ? AND b.start_ms<=?`,
    type.id, startMs, endMs, startMs, type.id, startMs, endMs + type.duration_ms, endMs);
  const out: Reading[] = [];
  for (const r of rows) {
    const points = r.data ? quantitySeries(r.data) : [[r.start_ms, r.end_ms, r.value ?? NaN] as const];
    for (const [s, e, v] of points) if (s >= startMs && s <= endMs && e <= endMs) {
      const bpm = nativeValue("heart_rate", v, r.unit); if (bpm !== null && Number.isFinite(bpm)) out.push({ ms: s, bpm, source: r.source, bundle: r.bundle });
    }
  }
  return out.sort((a, b) => a.ms - b.ms);
}

/** One source's readings when it recorded any (a workout's own Watch), else everyone's. */
export const ownOrAll = (rs: Reading[], source: string | null, bundle?: string | null) => {
  const own = source === null ? [] : rs.filter((r) => r.source === source && (bundle == null || r.bundle === bundle));
  return own.length ? own : rs;
};
