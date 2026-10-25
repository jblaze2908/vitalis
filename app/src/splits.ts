// Owner-defined splits (spec 11 §7.2): name + muscles, edited from Settings. History splits are derived in derived.ts.
import { z } from "zod";
import { now } from "./config.js";
import { all, one, run, tx } from "./db.js";
import { markDirty } from "./derived.js";
import { ApiError } from "./http.js";
import { SLUGS } from "./training-analytics.js";

export type SplitRow = { id: string; name: string; muscles: string[]; ord: number };

export const splitSchema = z.strictObject({
  name: z.string().trim().min(1).max(40),
  muscles: z.array(z.string().refine((m) => SLUGS.includes(m), "unknown muscle")).max(17),
  ord: z.number().int().min(0).max(999).optional(),
});

export function definedSplits(): SplitRow[] {
  return all<{ id: string; name: string; muscles: string; ord: number }>("SELECT id,name,muscles,ord FROM splits WHERE deleted_at IS NULL ORDER BY ord, created_at")
    .map((r) => ({ ...r, muscles: JSON.parse(r.muscles) as string[] }));
}

export function putSplit(id: string, body: z.infer<typeof splitSchema>) {
  if (!/^[\w-]{1,64}$/.test(id)) throw new ApiError(400, "split id must be 1–64 letters, digits, - or _", "bad_request");
  tx(() => {
    if (one("SELECT 1 FROM splits WHERE deleted_at IS NULL AND id!=? AND lower(name)=lower(?)", id, body.name))
      throw new ApiError(409, `A split named ${body.name} already exists`, "conflict");
    // A rename keeps its place; a new split goes last.
    const ord = body.ord ?? one<{ ord: number }>("SELECT ord FROM splits WHERE id=? AND deleted_at IS NULL", id)?.ord
      ?? one<{ n: number }>("SELECT COALESCE(MAX(ord)+1,0) n FROM splits WHERE deleted_at IS NULL")!.n;
    run(`INSERT INTO splits(id,name,muscles,ord,created_at,updated_at) VALUES (?,?,?,?,?,?)
      ON CONFLICT(id) DO UPDATE SET name=excluded.name, muscles=excluded.muscles, ord=excluded.ord, updated_at=excluded.updated_at, deleted_at=NULL`,
      id, body.name, JSON.stringify([...new Set(body.muscles)]), ord, now(), now());
    markDirty([]);
  });
  return { splits: definedSplits() };
}

export function deleteSplit(id: string) {
  tx(() => {
    if (!one("SELECT 1 FROM splits WHERE id=? AND deleted_at IS NULL", id)) throw new ApiError(404, `No split ${id}`);
    run("UPDATE splits SET deleted_at=?, updated_at=? WHERE id=?", now(), now(), id);
    markDirty([]);
  });
  return { splits: definedSplits() };
}
