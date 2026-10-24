// Opt-in phase measurements; normal ingest pays only a branch, with no clocks or profile I/O.
import { appendFileSync } from 'node:fs';
export const profile = process.env.VITALIS_PROFILE ? { sqlite: 0, parse: 0, validate: 0, hash: 0, derive: 0, derive_sql: 0, compress: 0, started: 0 } : undefined;
export function beginProfile() {
  if (!profile) return;
  for (const k of Object.keys(profile) as (keyof typeof profile)[]) profile[k] = 0;
  profile.started = performance.now();
}
export function endProfile(bytes: number) {
  if (!profile) return;
  const wall = performance.now() - profile.started;
  const sqlite = profile.sqlite - profile.derive_sql;
  appendFileSync(process.env.VITALIS_PROFILE!, JSON.stringify({ bytes, wall_ms: wall, parse_ms: profile.parse, validate_ms: profile.validate,
    sqlite_ms: sqlite, derive_ms: profile.derive, compress_ms: profile.compress, hash_ms: profile.hash,
    other_ms: wall - profile.parse - profile.validate - sqlite - profile.derive - profile.compress - profile.hash }) + '\n');
}
