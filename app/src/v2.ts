// Native sync: durable raw body first, then one atomic ledger + projection + batch commit.
import { createHash } from "node:crypto";
import { gzipSync } from "node:zlib";
import { httpErr, now } from "./config.js";
import { all, one, run, tx } from "./db.js";
import { Derivations, projectSample, type RawRow } from "./v2-derived.js";
import { KINDS, pack } from "./v2-storage.js";
import { stampParts } from "./v2-time.js";
import { beginProfile, endProfile, profile } from "./v2-profile.js";
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
  beginProfile();
  const sha = hash(body);
  let p = one<{ id: number }>("SELECT id FROM payloads WHERE sha256=?", sha);
  if (!p) {
    const t = profile ? performance.now() : 0, compressed = gzipSync(body);
    if (profile) profile.compress += performance.now() - t;
    p = { id: Number(run("INSERT INTO payloads(received_at,origin,sha256,bytes,body_gz) VALUES(?,'v2',?,?,?)", now(), sha, body.length, compressed).lastInsertRowid) };
  }
  try { return applyV2(p.id, body); } finally { endProfile(body.length); }
}

export function applyV2(id: number, body: Buffer, replay = false): SyncResult & { new_nights?: string[] } {
  try {
    const parseStarted = profile ? performance.now() : 0;
    let json: unknown;
    try { json = JSON.parse(body.toString("utf8")); } catch { throw httpErr(400, "Body is not JSON"); }
    const parsed = envelopeSchema.safeParse(json);
    if (!parsed.success) throw httpErr(400, `Invalid sync envelope: ${parsed.error.issues.map((i) => `${i.path.join(".")}: ${i.message}`).join("; ")}`);
    const envelope = parsed.data;
    if (profile) profile.parse += performance.now() - parseStarted;
    const touchedTypes = new Map<string, { live: number; deleted: number }>();
    const counter = (type: string, live: number, deleted: number) => {
      const delta = touchedTypes.get(type) ?? { live: 0, deleted: 0 };
      delta.live += live; delta.deleted += deleted; touchedTypes.set(type, delta);
    };
    const previous = one<Batch>("SELECT * FROM hk_batches WHERE batch_id=?", envelope.batch_id);
    if (previous && (!replay || previous.payload_id !== id)) {
      const stored = one<{ sha256: string }>("SELECT sha256 FROM payloads WHERE id=?", previous.payload_id)!;
      if (stored.sha256 !== hash(body)) throw httpErr(409, "batch_id already used with a different payload");
      recordPayload(id, JSON.parse(previous.counts_json), JSON.parse(previous.rejected_json));
      return result(previous, true);
    }
    const counts: Counts = { inserted: 0, updated: 0, unchanged: 0, deleted: 0, daily_stats: 0, rejected: 0 }, rejected: Rejection[] = [];
    const reject = (v: unknown, reason: string) => {
      const uuid = v && typeof v === "object" && "uuid" in v && typeof v.uuid === "string" ? v.uuid : null;
      counts.rejected++; rejected.push({ uuid, reason });
    };
    let derived!: Derivations;
    tx(() => {
    const uuids = JSON.stringify([...envelope.upserts, ...envelope.deletions].flatMap((v) =>
      v && typeof v === "object" && "uuid" in v && typeof v.uuid === "string" ? [v.uuid] : []));
    const oldRows = new Map(all<RawRow>("SELECT * FROM hk_raw WHERE uuid IN (SELECT value FROM json_each(?))", uuids).map((r) => [r.uuid, r]));
    const tombstones = new Map(all<{ uuid: string; type: string; deleted_at: number }>(
      "SELECT uuid,type,deleted_at FROM hk_tombstones WHERE uuid IN (SELECT value FROM json_each(?))", uuids).map((r) => [r.uuid, r]));
    const dailyRows = new Map(all<{ type: string; day: string; payload_id: number }>(
      "SELECT type,day,payload_id FROM hk_daily_stats WHERE type IN (SELECT CASE WHEN type='object' THEN json_extract(value,'$.type') END FROM json_each(?))", JSON.stringify(envelope.daily_stats)).map((r) => [JSON.stringify([r.type, r.day]), r]));
    derived = new Derivations(id, uuids);
    const types = new Map(all<{ id: number; identifier: string; duration_ms: number }>("SELECT id,identifier,duration_ms FROM hk_types").map(r => [r.identifier, r]));
    const sources = new Map(all<{ id: number; json: string }>("SELECT id,json FROM hk_sources").map(r => [r.json, r.id]));
    const devices = new Map(all<{ id: number; json: string }>("SELECT id,json FROM hk_devices").map(r => [r.json, r.id]));
    const sourceId = (s: Sample) => {
      const key = canonical(s.source); let id = sources.get(key);
      if (id === undefined) { id = Number(run("INSERT INTO hk_sources(name,bundle,json) VALUES(?,?,?)", s.source.name, s.source.bundle_id, key).lastInsertRowid); sources.set(key, id); }
      return id;
    };
    const deviceId = (s: Sample) => {
      if (s.device == null) return null;
      const key = canonical(s.device); let id = devices.get(key);
      if (id === undefined) { id = Number(run("INSERT INTO hk_devices(json) VALUES(?)", key).lastInsertRowid); devices.set(key, id); }
      return id;
    };
      for (const object of envelope.upserts) {
        const validationStarted = profile ? performance.now() : 0;
        const p = sampleSchema.safeParse(object);
        if (profile) profile.validate += performance.now() - validationStarted;
        if (!p.success) { reject(object, p.error.issues.map((i) => `${i.path.join(".")}: ${i.message}`).join("; ")); continue; }
        const s = p.data, old = oldRows.get(s.uuid);
        // Replaying old history must not undo a later replacement. --all still repairs the latest version.
        if (replay && old && old.payload_id > id) { counts.unchanged++; continue; }
        const hashStarted = profile ? performance.now() : 0, contentHash = hash(canonical(s));
        if (profile) profile.hash += performance.now() - hashStarted;
        if (old?.content_hash === contentHash && !replay) { counts.unchanged++; continue; }
        if (old) derived.touch(old);
        const tombstone = tombstones.get(s.uuid);
        if (tombstone && tombstone.type !== s.type) { reject(object, "Upsert type does not match tombstone"); continue; }
        const deletedAt = tombstone?.deleted_at ?? old?.deleted_at ?? null;
        if (old) counter(old.type, old.deleted_at === null ? -1 : 0, old.deleted_at !== null ? -1 : 0);
        else if (deletedAt !== null) counter(s.type, 0, -1); // the unknown tombstone already counted
        counter(s.type, deletedAt === null ? 1 : 0, deletedAt !== null ? 1 : 0);
        let type = types.get(s.type);
        if (!type) {
          const m = HK_METRICS.get(s.type);
          type = { id: Number(run("INSERT INTO hk_types(identifier,metric,cumulative) VALUES(?,?,?)", s.type, m?.def.key ?? null, m?.cumulative ? 1 : 0).lastInsertRowid), identifier: s.type, duration_ms: 0 };
          types.set(s.type, type);
        }
        let fresh: RawRow;
        if (deletedAt !== null) {
          run(`INSERT INTO hk_samples(uuid,type_id,content_hash,payload_id,created_at,updated_at,deleted_at) VALUES(?,?,?,?,?,?,?)
            ON CONFLICT(uuid) DO UPDATE SET content_hash=excluded.content_hash,payload_id=excluded.payload_id,updated_at=excluded.updated_at`,
            s.uuid, type.id, Buffer.from(contentHash, "hex"), id, now(), now(), deletedAt);
          if (old) clearContent(s.uuid);
          fresh = { id: old?.id ?? Number(one<{ id: number }>("SELECT id FROM hk_samples WHERE uuid=?", s.uuid)!.id), uuid: s.uuid, type: s.type, type_id: type.id, source_id: null,
            kind: "other", start_ms: 0, end_ms: 0, start_iso: "", end_iso: "", tz: null, source_name: "", source_bundle: "", category_value: null, extra_json: "{}",
            content_hash: contentHash, payload_id: id, deleted_at: deletedAt };
        } else {
          const from = Date.parse(s.start), to = Date.parse(s.end), a = stampParts(s.start), z = stampParts(s.end);
          type.duration_ms = Math.max(type.duration_ms, to - from);
          const extra: Record<string, unknown> = { ...s };
          for (const key of ["uuid", "type", "kind", "start", "end", "tz", "source", "device", "metadata"]) delete extra[key];
          if (s.kind === "quantity") { delete extra.value; delete extra.unit; delete extra.series; }
          if (s.kind === "category") delete extra.value;
          if (s.kind === "route") delete extra.points;
          if (s.kind === "heartbeat") delete extra.beats;
          if (s.kind === "ecg") delete extra.voltages_uv;
          const packed: Record<string, unknown> = {};
          if (Object.keys(extra).length) packed.extra = extra;
          if (s.metadata != null && Object.keys(s.metadata).length) packed.metadata = s.metadata;
          if (a.original || z.original) packed.times = { start: a.original, end: z.original };
          const projection = projectSample(s), src = sourceId(s), dev = deviceId(s);
          const stored = run(`INSERT INTO hk_samples(uuid,type_id,kind,start_ms,end_ms,start_offset,end_offset,start_format,end_format,tz,value,unit,category_value,
            source_id,device_id,json,day,native_value,content_hash,payload_id,created_at,updated_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(uuid) DO UPDATE SET type_id=excluded.type_id,kind=excluded.kind,
            start_ms=excluded.start_ms,end_ms=excluded.end_ms,start_offset=excluded.start_offset,end_offset=excluded.end_offset,start_format=excluded.start_format,
            end_format=excluded.end_format,tz=excluded.tz,value=excluded.value,unit=excluded.unit,category_value=excluded.category_value,source_id=excluded.source_id,
            device_id=excluded.device_id,json=excluded.json,day=excluded.day,native_value=excluded.native_value,content_hash=excluded.content_hash,
            payload_id=excluded.payload_id,updated_at=excluded.updated_at`,
            s.uuid, type.id, KINDS.indexOf(s.kind), from, to, a.offset, z.offset, a.format, z.format, s.tz ?? null,
            s.kind === "quantity" ? s.value : null, s.kind === "quantity" ? s.unit : null, s.kind === "category" ? s.value : null,
            src, dev, Object.keys(packed).length ? JSON.stringify(packed) : null, projection.day, projection.value, Buffer.from(contentHash, "hex"), id, now(), now());
          const sampleId = old?.id ?? Number(stored.lastInsertRowid);
          if (old) { run("DELETE FROM hk_blobs WHERE sample_id=?", sampleId); run("DELETE FROM hk_value_days WHERE sample_id=?", sampleId); }
          const blob = pack(s); if (blob) run("INSERT INTO hk_blobs(sample_id,data) VALUES(?,?)", sampleId, blob);
          if (s.type === "HKCategoryTypeIdentifierSleepAnalysis") run(`INSERT INTO hk_sleep_bounds(source,duration_ms) VALUES(?,?)
            ON CONFLICT(source) DO UPDATE SET duration_ms=MAX(duration_ms,excluded.duration_ms)`, s.source.name, to - from);
          derived.project(s, sampleId, projection);
          fresh = { id: sampleId, uuid: s.uuid, type: s.type, type_id: type.id, source_id: src, kind: s.kind, start_ms: from, end_ms: to,
            start_iso: s.start, end_iso: s.end, tz: s.tz ?? null, source_name: s.source.name, source_bundle: s.source.bundle_id,
            category_value: s.kind === "category" ? s.value : null, extra_json: JSON.stringify(extra), content_hash: contentHash, payload_id: id, deleted_at: null };
          derived.touch(fresh);
        }
        oldRows.set(s.uuid, fresh);
        if (!old) counts.inserted++; else if (old.content_hash === contentHash) counts.unchanged++; else counts.updated++;
      }
      for (const object of envelope.deletions) {
        const validationStarted = profile ? performance.now() : 0;
        const p = deletionSchema.safeParse(object);
        if (profile) profile.validate += performance.now() - validationStarted;
        if (!p.success) { reject(object, p.error.message); continue; }
        const { uuid, type } = p.data, old = oldRows.get(uuid);
        if (old && old.type !== type) { reject(object, "Deletion type does not match stored sample"); continue; }
        if (old) derived.touch(old);
        const marker = run("INSERT INTO hk_tombstones(uuid,type,deleted_at,payload_id) VALUES(?,?,?,?) ON CONFLICT(uuid) DO NOTHING", uuid, type, now(), id);
        const tombstone = tombstones.get(uuid) ?? { uuid, type, deleted_at: now() };
        tombstones.set(uuid, tombstone);
        run("UPDATE hk_samples SET deleted_at=?,updated_at=? WHERE uuid=? AND deleted_at IS NULL", tombstone.deleted_at, now(), uuid);
        clearContent(uuid);
        if (old) oldRows.set(uuid, { ...old, deleted_at: tombstone.deleted_at });
        if (marker.changes) counter(type, old?.deleted_at === null ? -1 : 0, old?.deleted_at !== null && old ? 0 : 1);
        counts.deleted += Number(marker.changes);
      }
      for (const object of envelope.daily_stats) {
        const validationStarted = profile ? performance.now() : 0;
        const p = dailySchema.safeParse(object);
        if (profile) profile.validate += performance.now() - validationStarted;
        if (!p.success) { reject(object, p.error.message); continue; }
        const s = p.data, m = HK_METRICS.get(s.type);
        if (m && (m.cumulative ? s.sum == null : [s.min, s.avg, s.max].every((v) => v == null))) {
          reject(object, m.cumulative ? "Cumulative daily statistic requires sum" : "Discrete daily statistic requires min, avg or max"); continue;
        }
        const old = dailyRows.get(JSON.stringify([s.type, s.day]));
        if (replay && old && old.payload_id > id) continue;
        run(`INSERT INTO hk_daily_stats(type,day,content_json,payload_id,updated_at) VALUES(?,?,?,?,?) ON CONFLICT(type,day)
          DO UPDATE SET content_json=excluded.content_json,payload_id=excluded.payload_id,updated_at=excluded.updated_at`, s.type, s.day, JSON.stringify(s), id, now());
        dailyRows.set(JSON.stringify([s.type, s.day]), { type: s.type, day: s.day, payload_id: id });
        derived.daily(s); counts.daily_stats++;
      }
      for (const t of types.values()) run("UPDATE hk_types SET duration_ms=MAX(duration_ms,?) WHERE id=?", t.duration_ms, t.id);
      const deriveStarted = profile ? performance.now() : 0, deriveSql = profile?.sqlite ?? 0;
      derived.finish();
      if (profile) { profile.derive += performance.now() - deriveStarted; profile.derive_sql += profile.sqlite - deriveSql; }
      for (const [type, delta] of touchedTypes) {
        run(`INSERT INTO hk_type_status(type,live,deleted) VALUES(?,?,?) ON CONFLICT(type)
          DO UPDATE SET live=live+excluded.live,deleted=deleted+excluded.deleted`, type, delta.live, delta.deleted);
        run(`UPDATE hk_type_status SET newest_end=(SELECT end_iso FROM hk_raw
          WHERE type=? AND deleted_at IS NULL ORDER BY end_ms DESC,uuid LIMIT 1) WHERE type=?`, type, type);
      }
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

function clearContent(uuid: string) {
  run("DELETE FROM hk_blobs WHERE sample_id=(SELECT id FROM hk_samples WHERE uuid=?)", uuid);
  run("DELETE FROM hk_value_days WHERE sample_id=(SELECT id FROM hk_samples WHERE uuid=?)", uuid);
  run(`UPDATE hk_samples SET kind=NULL,start_ms=NULL,end_ms=NULL,start_offset=NULL,end_offset=NULL,start_format=NULL,end_format=NULL,
    tz=NULL,value=NULL,unit=NULL,category_value=NULL,source_id=NULL,device_id=NULL,json=NULL,day=NULL,native_value=NULL WHERE uuid=?`, uuid);
}

export function syncStatus() {
  const batches = all<Batch>("SELECT * FROM hk_batches ORDER BY received_at DESC,payload_id DESC LIMIT 20");
  const types = all<{ type: string; live: number; deleted: number; newest_end: string | null }>(
    "SELECT type,live,deleted,newest_end FROM hk_type_status WHERE live+deleted>0 ORDER BY type");
  return { last_batch_at: batches.length ? new Date(batches[0].received_at).toISOString() : null, types,
    batches: batches.map((b) => ({ batch_id: b.batch_id, payload_id: b.payload_id, received_at: new Date(b.received_at).toISOString(),
      counts: JSON.parse(b.counts_json) as Counts, rejected: JSON.parse(b.rejected_json) as Rejection[] })) };
}
