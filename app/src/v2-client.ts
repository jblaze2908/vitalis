import { Worker } from 'node:worker_threads';
import { HttpError } from './config.js';
import { flushAudits } from './db.js';
import type { IngestMeta, IngestResult } from './ingest.js';
import type { SyncResult } from './v2.js';
type Result = (SyncResult | IngestResult) & { new_nights?: string[] };
let worker: Worker | undefined, seq = 0, queuedBytes = 0;
const pending = new Map<number, { bytes: number; resolve: (r: Result) => void; reject: (e: Error) => void }>();
function getWorker() {
  if (worker) return worker;
  const current = worker = new Worker(new URL('./v2-worker.js', import.meta.url), { execArgv: process.execArgv.filter((arg, i, args) =>
    !arg.startsWith('--input-type=') && arg !== '--input-type' && args[i - 1] !== '--input-type') });
  const fail = (e: Error) => {
    for (const p of pending.values()) p.reject(e);
    pending.clear(); queuedBytes = 0;
    if (worker === current) worker = undefined;
  };
  current.on('message', ({ id, result, error }: { id: number; result: Result; error?: { status: number; message: string; stack?: string } }) => {
    const p = pending.get(id); if (!p) return;
    pending.delete(id); queuedBytes -= p.bytes;
    flushAudits();
    if (!pending.size) current.unref();
    if (error) { const err = error.status === 500 ? new Error(error.message) : new HttpError(error.status, error.message); err.stack = error.stack; p.reject(err); }
    else p.resolve(result);
  });
  current.on('error', fail);
  current.on('exit', code => { if (worker === current) fail(new Error(`v2 ingest worker exited (${code})`)); });
  current.unref();
  return current;
}
export const ingestV2Async = (body: Buffer, encoding?: string) => submit(body, encoding) as Promise<SyncResult & { new_nights?: string[] }>;
/** Health Auto Export push on the same writer queue as native batches. */
export const ingestAsync = (body: Buffer, hae: IngestMeta) => submit(body, undefined, hae) as Promise<IngestResult>;
function submit(body: Buffer, encoding?: string, hae?: IngestMeta): Promise<Result> {
  if (pending.size >= 32 || queuedBytes + body.length > 128 * 1048576) return Promise.reject(new HttpError(503, 'Native ingest queue is full; retry this batch'));
  const current = getWorker(), id = ++seq;
  // Large HTTP bodies already own a dedicated Buffer.concat allocation. Transfer it without another copy.
  // Copy small/pooled or sliced buffers so unrelated bytes cannot be detached.
  const transferable: Uint8Array<ArrayBuffer> = body.buffer instanceof ArrayBuffer && body.byteOffset === 0 && body.byteLength === body.buffer.byteLength && body.length >= 4096
    ? new Uint8Array(body.buffer) : Uint8Array.from(body);
  return new Promise((resolve, reject) => {
    pending.set(id, { bytes: body.length, resolve, reject }); queuedBytes += body.length; current.ref();
    current.postMessage({ id, body: transferable, encoding, hae }, [transferable.buffer]);
  });
}
