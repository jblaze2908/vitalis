import * as zlib from 'node:zlib';
// Only native payloads opt into zstd; existing HAE rows/writers retain gzip.
export function compressNative(body: Buffer) {
  if (typeof zlib.zstdCompressSync === 'function' && process.env.VITALIS_PAYLOAD_CODEC !== 'gzip') return { codec: 'zstd', body: zlib.zstdCompressSync(body) };
  return { codec: 'gzip', body: zlib.gzipSync(body) };
}
export function decodePayload(body: Uint8Array, codec = 'gzip'): Buffer {
  if (codec === 'gzip') return zlib.gunzipSync(body);
  if (codec === 'zstd' && typeof zlib.zstdDecompressSync === 'function') return zlib.zstdDecompressSync(body);
  throw new Error(`Unsupported stored payload codec: ${codec}`);
}
