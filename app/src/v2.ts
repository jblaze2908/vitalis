// Native sync: durable raw body first, then one atomic ledger + projection + batch commit.
import { createHash } from "node:crypto";
import { gzipSync } from "node:zlib";
import { httpErr, now } from "./config.js";
import { all, db, one, run, tx } from "./db.js";
import { Derivations, type RawRow } from "./v2-derived.js";
import { HK_METRICS } from "./v2-metrics.js";
import { dailySchema, deletionSchema, envelopeSchema, sampleSchema, type Sample } from "./v2-schema.js";

export type Counts = { inserted: number; updated: number; unchanged: number; deleted: number; daily_stats: number; rejected: number };
export type Rejection = { uuid: string | null; reason: string };
export type SyncResult = { batch_id: string; duplicate: boolean; counts: Counts; rejected: Rejection[] };
type Batch = { batch_id: string; payload_id: number; received_at: number; counts_json: string; rejected_json: string };
const hash = (s: string | Buffer) => createHash("sha256").update(s).digest("hex");
// Object key order is not sample content. Array order, nulls, unknown fields and numeric precision are retained.
function canonical(v: unknown): string {
  if (Array.isArray(v)) return `[${v.map(canonical).join(",")}]`;
  if (v !== null && typeof v === "object") return `{${Object.keys(v).sort().map((k) => `${JSON.stringify(k)}:${canonical((v as Record<string, unknown>)[k])}`).join(",")}}`;
  return JSON.stringify(v);
}
const result = (b: Batch, duplicate: boolean): SyncResult => ({ batch_id: b.batch_id, duplicate, counts: JSON.parse(b.counts_json), rejected: JSON.parse(b.rejected_json) });

export function ingestV2(body: Buffer): SyncResult & { new_nights?: string[] } {
  const sha = hash(body);
  let p = one<{ id: number }>("SELECT id FROM payloads WHERE sha256=?", sha);
  if (!p) p = { id: Number(run("INSERT INTO payloads(received_at,origin,sha256,bytes,body_gz) VALUES(?,'v2',?,?,?)", now(), sha, body.length, gzipSync(body)).lastInsertRowid) };
  return applyV2(p.id, body);
}

export function applyV2(id: number, body: Buffer, replay = false): SyncResult & { new_nights?: string[] } {
  try {
    let json: unknown;
    try { json = JSON.parse(body.toString("utf8")); } catch { throw httpErr(400, "Body is not JSON"); }
    const parsed = envelopeSchema.safeParse(json);
    if (!parsed.success) throw httpErr(400, `Invalid sync envelope: ${parsed.error.issues.map((i) => `${i.path.join(".")}: ${i.message}`).join("; ")}`);
    const envelope = parsed.data;
    const previous = one<Batch>("SELECT * FROM hk_batches WHERE batch_id=?", envelope.batch_id);
    if (previous && (!replay || previous.payload_id !== id)) {
      recordPayload(id, JSON.parse(previous.counts_json), JSON.parse(previous.rejected_json));
      return result(previous, true);
    }
    const counts: Counts = { inserted: 0, updated: 0, unchanged: 0, deleted: 0, daily_stats: 0, rejected: 0 }, rejected: Rejection[] = [];
    const derived = new Derivations(id);
    const reject = (v: unknown, reason: string) => {
      const uuid = v && typeof v === "object" && "uuid" in v && typeof v.uuid === "string" ? v.uuid : null;
      counts.rejected++; rejected.push({ uuid, reason });
    };
    tx(() => {
      for (const object of envelope.upserts) {
        const p = sampleSchema.safeParse(object);
        if (!p.success) { reject(object, p.error.issues.map((i) => `${i.path.join(".")}: ${i.message}`).join("; ")); continue; }
        const s = p.data, old = one<RawRow>("SELECT * FROM hk_samples WHERE uuid=?", s.uuid);
        // Replaying old history must not undo a later replacement. --all still repairs the latest version.
        if (replay && old && old.payload_id > id) { counts.unchanged++; continue; }
        const contentHash = hash(canonical(s));
        if (old?.content_hash === contentHash && !replay) { counts.unchanged++; continue; }
        if (old) derived.touch(old);
        const deletedAt = one<{ deleted_at: number }>("SELECT deleted_at FROM hk_tombstones WHERE uuid=?", s.uuid)?.deleted_at ?? old?.deleted_at ?? null;
        const extra: Record<string, unknown> = { ...s };
        for (const key of ["uuid", "type", "start", "end", "tz", "source", "device", "metadata"]) delete extra[key];
        if (s.kind === "quantity") { delete extra.value; delete extra.unit; delete extra.series; }
        if (s.kind === "category") delete extra.value;
        if (s.kind === "route") delete extra.points;
        if (s.kind === "heartbeat") delete extra.beats;
        run(`INSERT INTO hk_samples(uuid,type,kind,start_ms,end_ms,start_iso,end_iso,tz,value,unit,category_value,source_name,source_bundle,
          source_json,device_json,metadata_json,extra_json,content_hash,payload_id,created_at,updated_at,deleted_at)
          VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(uuid) DO UPDATE SET type=excluded.type,kind=excluded.kind,
          start_ms=excluded.start_ms,end_ms=excluded.end_ms,start_iso=excluded.start_iso,end_iso=excluded.end_iso,tz=excluded.tz,value=excluded.value,
          unit=excluded.unit,category_value=excluded.category_value,source_name=excluded.source_name,source_bundle=excluded.source_bundle,
          source_json=excluded.source_json,device_json=excluded.device_json,metadata_json=excluded.metadata_json,extra_json=excluded.extra_json,
          content_hash=excluded.content_hash,payload_id=excluded.payload_id,updated_at=excluded.updated_at,deleted_at=excluded.deleted_at`,
          s.uuid, s.type, s.kind, Date.parse(s.start), Date.parse(s.end), s.start, s.end, s.tz ?? null,
          s.kind === "quantity" ? s.value : null, s.kind === "quantity" ? s.unit : null, s.kind === "category" ? s.value : null,
          s.source.name, s.source.bundle_id, JSON.stringify(s.source), s.device === undefined ? null : JSON.stringify(s.device),
          s.metadata === undefined ? null : JSON.stringify(s.metadata), JSON.stringify(extra), contentHash, id, now(), now(), deletedAt);
        children(s);
        derived.project(s, deletedAt === null);
        derived.touch(one<RawRow>("SELECT * FROM hk_samples WHERE uuid=?", s.uuid)!);
        if (!old) counts.inserted++; else if (old.content_hash === contentHash) counts.unchanged++; else counts.updated++;
      }
      for (const object of envelope.deletions) {
        const p = deletionSchema.safeParse(object);
        if (!p.success) { reject(object, p.error.message); continue; }
        const { uuid, type } = p.data, old = one<RawRow>("SELECT * FROM hk_samples WHERE uuid=?", uuid);
        if (old && old.type !== type) { reject(object, "Deletion type does not match stored sample"); continue; }
        if (old) derived.touch(old);
        const marker = run("INSERT INTO hk_tombstones(uuid,type,deleted_at,payload_id) VALUES(?,?,?,?) ON CONFLICT(uuid) DO NOTHING", uuid, type, now(), id);
        const tombstone = one<{ deleted_at: number }>("SELECT deleted_at FROM hk_tombstones WHERE uuid=?", uuid)!;
        run("UPDATE hk_samples SET deleted_at=?,updated_at=? WHERE uuid=? AND deleted_at IS NULL", tombstone.deleted_at, now(), uuid);
        run("DELETE FROM hk_sample_values WHERE uuid=?", uuid);
        counts.deleted += Number(marker.changes);
      }
      for (const object of envelope.daily_stats) {
        const p = dailySchema.safeParse(object);
        if (!p.success) { reject(object, p.error.message); continue; }
        const s = p.data, m = HK_METRICS.get(s.type);
        if (m && (m.cumulative ? s.sum == null : [s.min, s.avg, s.max].every((v) => v == null))) {
          reject(object, m.cumulative ? "Cumulative daily statistic requires sum" : "Discrete daily statistic requires min, avg or max"); continue;
        }
        const old = one<{ payload_id: number }>("SELECT payload_id FROM hk_daily_stats WHERE type=? AND day=?", s.type, s.day);
        if (replay && old && old.payload_id > id) continue;
        run(`INSERT INTO hk_daily_stats(type,day,content_json,payload_id,updated_at) VALUES(?,?,?,?,?) ON CONFLICT(type,day)
          DO UPDATE SET content_json=excluded.content_json,payload_id=excluded.payload_id,updated_at=excluded.updated_at`, s.type, s.day, JSON.stringify(s), id, now());
        derived.daily(s); counts.daily_stats++;
      }
      derived.finish();
      const received = one<{ received_at: number }>("SELECT received_at FROM payloads WHERE id=?", id)!.received_at;
      run(`INSERT INTO hk_batches(batch_id,payload_id,received_at,counts_json,rejected_json) VALUES(?,?,?,?,?) ON CONFLICT(batch_id)
        DO UPDATE SET counts_json=excluded.counts_json,rejected_json=excluded.rejected_json`, envelope.batch_id, id, received, JSON.stringify(counts), JSON.stringify(rejected));
      recordPayload(id, counts, rejected);
    });
    return { batch_id: envelope.batch_id, duplicate: false, counts, rejected, new_nights: derived.newNights };
  } catch (e) {
    run("UPDATE payloads SET error=? WHERE id=?", (e as Error).message.slice(0, 500), id);
    throw e;
  }
}

function recordPayload(id: number, counts: Counts, rejected: Rejection[]) {
  run("UPDATE payloads SET parsed_at=?,counts=?,warnings=?,error=NULL WHERE id=?", now(), JSON.stringify(counts),
    JSON.stringify(rejected.map((r) => `${r.uuid ?? "object"}: ${r.reason}`)), id);
}

function children(s: Sample) {
  for (const table of ["hk_quantity_points", "hk_route_points", "hk_heartbeat_beats"]) run(`DELETE FROM ${table} WHERE uuid=?`, s.uuid);
  if (s.kind === "quantity" && s.series) {
    const insert = db.prepare("INSERT INTO hk_quantity_points(uuid,ord,start_iso,end_iso,start_ms,end_ms,value) VALUES(?,?,?,?,?,?,?)");
    s.series.forEach(([start, end, value], ord) => insert.run(s.uuid, ord, start, end, Date.parse(start), Date.parse(end), value));
  }
  if (s.kind === "route") {
    const insert = db.prepare("INSERT INTO hk_route_points(uuid,ord,time_iso,lat,lon,alt_m,h_acc_m,v_acc_m,speed_mps,course_deg) VALUES(?,?,?,?,?,?,?,?,?,?)");
    s.points.forEach((p, ord) => insert.run(s.uuid, ord, ...p));
  }
  if (s.kind === "heartbeat") {
    const insert = db.prepare("INSERT INTO hk_heartbeat_beats(uuid,ord,seconds,preceded_by_gap) VALUES(?,?,?,?)");
    s.beats.forEach(([seconds, gap], ord) => insert.run(s.uuid, ord, seconds, gap ? 1 : 0));
  }
}

export function syncStatus() {
  const batches = all<Batch>("SELECT * FROM hk_batches ORDER BY received_at DESC,payload_id DESC LIMIT 20");
  const types = all<{ type: string; live: number; deleted: number; newest_end: string | null }>(`WITH objects AS (
    SELECT type,deleted_at,end_iso,end_ms FROM hk_samples UNION ALL
    SELECT t.type,t.deleted_at,NULL,NULL FROM hk_tombstones t WHERE NOT EXISTS (SELECT 1 FROM hk_samples s WHERE s.uuid=t.uuid)
  ) SELECT type,SUM(deleted_at IS NULL) live,SUM(deleted_at IS NOT NULL) deleted,
    (SELECT s.end_iso FROM hk_samples s WHERE s.type=objects.type AND s.deleted_at IS NULL ORDER BY s.end_ms DESC,s.uuid LIMIT 1) newest_end
    FROM objects GROUP BY type ORDER BY type`);
  return { last_batch_at: batches.length ? new Date(batches[0].received_at).toISOString() : null, types,
    batches: batches.map((b) => ({ batch_id: b.batch_id, payload_id: b.payload_id, received_at: new Date(b.received_at).toISOString(),
      counts: JSON.parse(b.counts_json) as Counts, rejected: JSON.parse(b.rejected_json) as Rejection[] })) };
}
