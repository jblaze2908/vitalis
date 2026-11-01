// Outbound events for agents: "sleep.ready" once per day, when the night ending today first arrives, so a morning brief
// can go out whenever the owner actually wakes. Standard Webhooks signing (HMAC-SHA256 over "id.timestamp.body").
// The payload names the day only; the receiver reads values over MCP. Runs after the push is answered: one insert, one POST.
import { createHmac, randomUUID } from "node:crypto";
import { HOOK_SECRET, HOOK_URL, now } from "./config.js";
import { one, run } from "./db.js";
import { today } from "./time.js";

export const hooksOn = () => !!HOOK_URL && !!HOOK_SECRET;

export function sign(secret: string, id: string, ts: number, body: string) {
  const key = Buffer.from(secret.replace(/^whsec_/, ""), "base64");
  return `v1,${createHmac("sha256", key).update(`${id}.${ts}.${body}`).digest("base64")}`;
}

// A claim older than this belongs to a delivery that died mid-flight; three attempts finish in about 75 s.
const CLAIM_TTL_MS = 5 * 60_000;

/** Fire sleep.ready once today's night has arrived; every later push that day retries it until it is delivered. Never throws. */
export async function afterIngest(days: string[] | undefined) {
  if (!hooksOn()) return;
  const day = today();
  // The night is new only on its first push; the row made then is what later pushes retry from.
  if (days?.includes(day)) run("INSERT OR IGNORE INTO hook_events(event,day,created_at) VALUES('sleep.ready',?,?)", day, now());
  // Atomic claim, one primary-key UPDATE per push: HAE pushes (main thread) and native batches (worker) use separate connections.
  const t = now();
  if (run(`UPDATE hook_events SET claimed_at=? WHERE event='sleep.ready' AND day=? AND sent_at IS NULL
           AND (claimed_at IS NULL OR claimed_at < ?)`, t, day, t - CLAIM_TTL_MS).changes === 0) return;
  await deliver("sleep.ready", day);
}

async function deliver(event: string, day: string) {
  const body = JSON.stringify({ type: event, day, timestamp: new Date().toISOString() });
  for (let attempt = 1; attempt <= 3; attempt++) {
    const id = `msg_${randomUUID()}`, ts = Math.floor(Date.now() / 1000);
    let status = "";
    try {
      const r = await fetch(HOOK_URL, { method: "POST", body, signal: AbortSignal.timeout(10_000),
        headers: { "content-type": "application/json", "webhook-id": id, "webhook-timestamp": String(ts), "webhook-signature": sign(HOOK_SECRET, id, ts, body) } });
      status = String(r.status);
      if (r.ok) { run("UPDATE hook_events SET sent_at=?,status=?,attempts=? WHERE event=? AND day=?", now(), status, attempt, event, day); return; }
    } catch (e) { status = (e as Error).name; }
    run("UPDATE hook_events SET status=?,attempts=? WHERE event=? AND day=?", status, attempt, event, day);
    if (attempt < 3) await new Promise((ok) => setTimeout(ok, attempt * 15_000));
  }
  run("UPDATE hook_events SET claimed_at=NULL WHERE event=? AND day=?", event, day);
  console.error(`hook ${event} ${day} failed after 3 attempts; the next push today retries it`);
}

export const lastHook = () => one<{ event: string; day: string; sent_at: number | null; status: string | null; attempts: number }>(
  "SELECT event,day,sent_at,status,attempts FROM hook_events ORDER BY created_at DESC LIMIT 1") ?? null;
