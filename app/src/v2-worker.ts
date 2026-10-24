// The HTTP hot path runs in this thread on its own SQLite connection.
import { parentPort } from 'node:worker_threads';
import { gunzipSync } from 'node:zlib';
import { HttpError, MAX_INGEST_BYTES } from './config.js';
import { afterIngest } from './hooks.js';
import { ingest, type IngestMeta } from './ingest.js';
import { ingestV2 } from './v2.js';
if (!parentPort) throw new Error('v2-worker requires a parent port');
// One writer for every ingest: native batches and Health Auto Export pushes queue here, so they never contend for the write lock.
parentPort.on('message', ({ id, body, encoding, hae }: { id: number; body: Uint8Array; encoding?: string; hae?: IngestMeta }) => {
  try {
    let raw = Buffer.from(body.buffer, body.byteOffset, body.byteLength);
    if (encoding === 'gzip') {
      try { raw = gunzipSync(raw, { maxOutputLength: MAX_INGEST_BYTES }); }
      catch (e) {
        if ((e as NodeJS.ErrnoException).code === 'ERR_BUFFER_TOO_LARGE') throw new HttpError(413, 'Decompressed body exceeds ingest size limit');
        throw new HttpError(400, 'Invalid gzip body');
      }
    }
    // HAE's afterIngest hook runs on the main thread, after this reply, exactly as it did before the queue.
    if (hae) { parentPort!.postMessage({ id, result: ingest(raw, hae) }); return; }
    const result = ingestV2(raw);
    // Hook database writes also stay off the HTTP/read thread while another batch is queued.
    void afterIngest(result.new_nights).catch(e => console.error('v2 hook failed:', (e as Error).message));
    parentPort!.postMessage({ id, result });
  } catch (e) {
    const err = e as Error;
    parentPort!.postMessage({ id, error: { message: err.message, status: err instanceof HttpError ? err.status : 500, stack: err.stack } });
  }
});
