// Admin without a UI: tokens, backfill imports, replays and the sync log.
import { readFileSync } from "node:fs";
import { HttpError } from "./config.js";
import { all } from "./db.js";
import { seedExercises } from "./exercises.js";
import { freshness } from "./health.js";
import { ingest, payloadIds, reparse } from "./ingest.js";
import { createToken, listTokens, revokeToken, SCOPES, type Scope } from "./tokens.js";

const HELP = `vitalis <command>
  token create <name> --scope ingest|read|write   print a new token (shown once)
  token list                                      tokens, scope, last use
  token revoke <id|name>
  import <file.json> [...]                        backfill: a Health Auto Export JSON export (Export Version 2, Time Grouping Day)
  reparse [--all | <payload id>]                  parse stored pushes again after an upgrade
  syncs [n]                                       the last n pushes (default 20)
  freshness                                       what data is here and how current`;

const iso = (ms: number | null) => (ms ? new Date(ms).toISOString().slice(0, 16).replace("T", " ") : "—");

function main(argv: string[]) {
  const [cmd, sub, ...rest] = argv;
  if (cmd === "token" && sub === "create") {
    const name = rest.find((a) => !a.startsWith("--")) ?? "";
    const i = rest.indexOf("--scope"), scope = (i >= 0 ? rest[i + 1] : "") as Scope;
    if (!SCOPES.includes(scope)) throw new HttpError(400, `--scope is one of ${SCOPES.join(", ")}`);
    const t = createToken(name, scope);
    console.log(`${t.name} (${t.scope}): ${t.token}\nShown once. Store it in your password manager.`);
  } else if (cmd === "token" && sub === "list") {
    for (const t of listTokens()) console.log(`${t.id}  ${t.name.padEnd(24)} ${t.scope.padEnd(6)} ${t.prefix}…  used ${iso(t.last_used_at)}${t.revoked_at ? "  REVOKED" : ""}`);
  } else if (cmd === "token" && sub === "revoke") {
    revokeToken(rest[0] ?? "");
    console.log("Revoked.");
  } else if (cmd === "import") {
    seedExercises();
    for (const f of [sub, ...rest].filter(Boolean)) {
      const r = ingest(readFileSync(f), { origin: "import" });
      console.log(`${f}: ${r.duplicate ? "already imported" : "imported"} ${JSON.stringify(r.counts)}${r.warnings.length ? `\n  ${r.warnings.join("\n  ")}` : ""}`);
    }
  } else if (cmd === "reparse") {
    const ids = sub === "--all" ? payloadIds() : [Number(sub)];
    for (const id of ids) { const r = reparse(id); console.log(`payload ${id}: ${JSON.stringify(r.counts)}${r.warnings.length ? ` (${r.warnings.length} warnings)` : ""}`); }
  } else if (cmd === "syncs") {
    const rows = all<{ id: number; received_at: number; origin: string; automation: string | null; bytes: number; counts: string | null; warnings: string | null; error: string | null }>(
      "SELECT id,received_at,origin,automation,bytes,counts,warnings,error FROM payloads ORDER BY id DESC LIMIT ?", Number(sub ?? 20));
    for (const r of rows) console.log(`${r.id}  ${iso(r.received_at)}  ${r.origin}  ${r.automation ?? ""}  ${r.bytes} B  ${r.counts ?? ""}${r.error ? `  ERROR ${r.error}` : ""}${r.warnings && r.warnings !== "[]" ? `  ${r.warnings}` : ""}`);
  } else if (cmd === "freshness") {
    console.log(JSON.stringify(freshness(), null, 2));
  } else {
    console.log(HELP);
    if (cmd && cmd !== "help") process.exitCode = 1;
  }
}

try { main(process.argv.slice(2)); } catch (e) { console.error((e as Error).message); process.exitCode = 1; }
