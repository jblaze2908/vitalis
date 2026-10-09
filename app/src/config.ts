import { mkdirSync } from "node:fs";
import { resolve } from "node:path";

export const ROOT = resolve(process.env.VITALIS_ROOT ?? ".data");
mkdirSync(ROOT, { recursive: true });
export const PORT = Number(process.env.PORT ?? 8350);
// Loopback by default: the reverse proxy is the only public door.
export const BIND = process.env.VITALIS_BIND ?? "127.0.0.1";
// Public host, for the Origin check on /mcp. Unset in dev.
export const HOST = process.env.VITALIS_HOST ?? "";
// The owner's zone decides what "today" and "last night" mean when a caller gives no date.
export const TZ = process.env.VITALIS_TZ ?? process.env.TZ ?? "UTC";
export const MAX_INGEST_BYTES = Number(process.env.VITALIS_MAX_INGEST_MB ?? 50) << 20;

export const now = () => Date.now();

export class HttpError extends Error {
  constructor(public status: number, message: string) { super(message); }
}
export const httpErr = (status: number, message: string) => new HttpError(status, message);
