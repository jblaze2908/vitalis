// Packed v1 layout is documented in docs/v2-storage.md. Float64 keeps JSON number precision.
import { all, db, one, run } from './db.js';
import type { Sample } from './v2-schema.js';
export const KINDS = ['quantity', 'category', 'workout', 'route', 'heartbeat', 'ecg', 'correlation', 'state_of_mind', 'other'] as const;
import { stampParts, rebuildISO } from "./v2-time.js";
// One packed blob per sample. Header: version:u8, kind:u8, stride:u16LE, count:u32LE, JSON trailer length:u32LE.
const HEADER = 12;
export function pack(s: Sample): Buffer | null {
  let count: number, stride: number;
  if (s.kind === 'quantity' && s.series?.length) { count = s.series.length; stride = 32; }
  else if (s.kind === 'route') { count = s.points.length; stride = 68; }
  else if (s.kind === 'heartbeat') { count = s.beats.length; stride = 9; }
  else if (s.kind === 'ecg') { count = s.voltages_uv.length; stride = 8; }
  else return null;
  const b = Buffer.alloc(HEADER + count * stride), originals: Record<string, string> = {};
  b.writeUInt8(1, 0); b.writeUInt8(KINDS.indexOf(s.kind), 1); b.writeUInt16LE(stride, 2); b.writeUInt32LE(count, 4);
  const time = (iso: string, at: number, key: string) => {
    const t = stampParts(iso); b.writeDoubleLE(Date.parse(iso), at); b.writeInt16LE(t.offset, at + 8); b.writeUInt8(t.format, at + 10);
    if (t.original) originals[key] = t.original;
  };
  for (let i = 0; i < count; i++) {
    const at = HEADER + i * stride;
    if (s.kind === 'quantity' && s.series) {
      const [start, end, value] = s.series[i];
      b.writeDoubleLE(Date.parse(start), at); b.writeDoubleLE(Date.parse(end), at + 8); b.writeDoubleLE(value, at + 16);
      const a = stampParts(start), z = stampParts(end); b.writeInt16LE(a.offset, at + 24); b.writeInt16LE(z.offset, at + 26);
      b.writeUInt8(a.format, at + 28); b.writeUInt8(z.format, at + 29);
      if (a.original) originals[`${i}s`] = a.original; if (z.original) originals[`${i}e`] = z.original;
    } else if (s.kind === 'route') {
      time(s.points[i][0], at, String(i));
      for (let k = 1; k < 8; k++) b.writeDoubleLE(s.points[i][k] as number, at + 12 + (k - 1) * 8);
    } else if (s.kind === 'heartbeat') {
      b.writeDoubleLE(s.beats[i][0], at); b.writeUInt8(s.beats[i][1] ? 1 : 0, at + 8);
    } else if (s.kind === 'ecg') b.writeDoubleLE(s.voltages_uv[i], at);
  }
  if (!Object.keys(originals).length) return b;
  const trailer = Buffer.from(JSON.stringify(originals)); b.writeUInt32LE(trailer.length, 8); return Buffer.concat([b, trailer]);
}
export function unpack(bytes: Uint8Array): unknown[][] | number[] {
  const b = Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const kind = KINDS[b[1]], stride = b.readUInt16LE(2), count = b.readUInt32LE(4), trailer = b.readUInt32LE(8);
  if (b[0] !== 1 || HEADER + stride * count + trailer !== b.length) throw new Error('Invalid packed HealthKit blob');
  const originals = trailer ? JSON.parse(b.toString('utf8', HEADER + stride * count)) as Record<string, string> : {};
  const out: (unknown[] | number)[] = [];
  for (let i = 0; i < count; i++) {
    const at = HEADER + i * stride;
    if (kind === 'quantity') out.push([
      rebuildISO(b.readDoubleLE(at), b.readInt16LE(at + 24), b[at + 28], originals[`${i}s`]),
      rebuildISO(b.readDoubleLE(at + 8), b.readInt16LE(at + 26), b[at + 29], originals[`${i}e`]), b.readDoubleLE(at + 16)]);
    else if (kind === 'route') out.push([rebuildISO(b.readDoubleLE(at), b.readInt16LE(at + 8), b[at + 10], originals[i]),
      ...Array.from({ length: 7 }, (_, k) => b.readDoubleLE(at + 12 + k * 8))]);
    else if (kind === 'heartbeat') out.push([b.readDoubleLE(at), !!b[at + 8]]);
    else if (kind === 'ecg') out.push(b.readDoubleLE(at));
  }
  return out as unknown[][] | number[];
}
export const blobFor = (uuid: string) => one<{ data: Uint8Array }>('SELECT data FROM hk_blobs WHERE sample_id=(SELECT id FROM hk_samples WHERE uuid=?)', uuid)?.data;
/** A quantity series blob as [start_ms, end_ms, value] rows, skipping the ISO rebuild `unpack` does for every point. */
export function quantitySeries(bytes: Uint8Array): [number, number, number][] {
  const b = Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (b[0] !== 1 || KINDS[b[1]] !== 'quantity') return [];
  const stride = b.readUInt16LE(2), count = b.readUInt32LE(4), out: [number, number, number][] = [];
  for (let i = 0; i < count; i++) { const at = HEADER + i * stride; out.push([b.readDoubleLE(at), b.readDoubleLE(at + 8), b.readDoubleLE(at + 16)]); }
  return out;
}
