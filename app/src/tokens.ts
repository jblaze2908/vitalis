// Bearer tokens, stored only as SHA-256. Scopes: ingest (POST /ingest only), read (MCP reads), write (MCP reads and writes).
import { createHash, randomBytes, randomUUID, timingSafeEqual } from "node:crypto";
import { all, one, run } from "./db.js";
import { httpErr, now } from "./config.js";

export type Scope = "ingest" | "read" | "write";
export type Token = { id: string; name: string; scope: Scope };
export const SCOPES: Scope[] = ["ingest", "read", "write"];
const PREFIX = "vtl_";

export const sha = (s: string) => createHash("sha256").update(s).digest("hex");

export function createToken(name: string, scope: Scope) {
  if (!SCOPES.includes(scope)) throw httpErr(400, `scope is one of ${SCOPES.join(", ")}`);
  if (!name.trim() || name.length > 80) throw httpErr(400, "Give the token a name of up to 80 characters");
  const secret = PREFIX + randomBytes(32).toString("base64url"), id = randomUUID();
  run("INSERT INTO tokens(id,name,scope,hash,prefix,created_at) VALUES(?,?,?,?,?,?)", id, name.trim(), scope, sha(secret), secret.slice(0, 10), now());
  return { id, name: name.trim(), scope, token: secret };
}

export function authenticate(header: string | undefined): Token | null {
  const m = /^Bearer\s+(\S+)$/i.exec(header ?? "");
  if (!m || !m[1].startsWith(PREFIX)) return null;
  const h = sha(m[1]);
  const row = one<Token & { hash: string; last_used_at: number | null }>("SELECT id,name,scope,hash,last_used_at FROM tokens WHERE hash=? AND revoked_at IS NULL", h);
  if (!row || !timingSafeEqual(Buffer.from(row.hash), Buffer.from(h))) return null;
  // One write a minute at most per token; a busy agent shouldn't turn reads into writes.
  if (!row.last_used_at || now() - row.last_used_at > 60_000) run("UPDATE tokens SET last_used_at=? WHERE id=?", now(), row.id);
  return { id: row.id, name: row.name, scope: row.scope };
}

export const listTokens = () =>
  all<{ id: string; name: string; scope: Scope; prefix: string; created_at: number; last_used_at: number | null; revoked_at: number | null }>(
    "SELECT id,name,scope,prefix,created_at,last_used_at,revoked_at FROM tokens ORDER BY created_at");

export function revokeToken(idOrName: string) {
  const r = run("UPDATE tokens SET revoked_at=? WHERE (id=? OR name=?) AND revoked_at IS NULL", now(), idOrName, idOrName);
  if (!r.changes) throw httpErr(404, "No live token with that id or name");
  return Number(r.changes);
}

export function logCall(tokenId: string | null, tool: string, ok: boolean, ms: number, detail: string | null) {
  run("INSERT INTO calls(at,token_id,tool,ok,ms,detail) VALUES(?,?,?,?,?,?)", now(), tokenId, tool, ok ? 1 : 0, ms, detail);
}
