// Isolate key layout and PRAGMA decisions from parsing/validation. Synthetic, file-backed SQLite.
import { DatabaseSync } from 'node:sqlite';
import { mkdtempSync, mkdirSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
mkdirSync('.data/bench', { recursive: true });
const dir = mkdtempSync('.data/bench/vitalis-storage-');
const n = Number(process.env.STORAGE_N ?? 1000000);
const results = [];
for (const [name, layout, page, cache, mmap, checkpoint] of [
  ['integer-text-4k', 'integer', 4096, 16384, 0, 1000],
  ['blob-without-rowid-4k', 'blob', 4096, 16384, 0, 1000],
  ['integer-text-8k', 'integer', 8192, 16384, 0, 1000],
  ['integer-text-16k', 'integer', 16384, 16384, 0, 1000],
  ['integer-text-64m', 'integer', 4096, 65536, 0, 1000],
  ['integer-text-mmap', 'integer', 4096, 16384, 268435456, 1000],
  ['integer-text-checkpoint', 'integer', 4096, 16384, 268435456, 8192],
]) {
  const path = join(dir, name + '.db'), db = new DatabaseSync(path);
  db.exec(`PRAGMA page_size=${page}; PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA cache_size=-${cache}; PRAGMA mmap_size=${mmap}; PRAGMA temp_store=MEMORY; PRAGMA wal_autocheckpoint=${checkpoint};
    CREATE TABLE samples (${layout === 'integer' ? 'id INTEGER PRIMARY KEY,uuid TEXT NOT NULL UNIQUE' : 'uuid BLOB PRIMARY KEY'},type_id INTEGER,source_id INTEGER,device_id INTEGER,start_ms INTEGER,end_ms INTEGER,offset_min INTEGER,value REAL,unit TEXT,day TEXT,hash BLOB,payload_id INTEGER) ${layout === 'blob' ? 'WITHOUT ROWID' : ''};
    CREATE INDEX by_day ON samples(type_id,day,source_id); CREATE INDEX by_time ON samples(type_id,start_ms,end_ms);`);
  const insert = db.prepare('INSERT INTO samples(uuid,type_id,source_id,device_id,start_ms,end_ms,offset_min,value,unit,day,hash,payload_id) VALUES(?,1,1,1,?,?,0,70,\'count/min\',?,?,?)');
  const key = i => { const b = Buffer.alloc(16); b.writeUInt32BE(Math.imul(i, 2654435761) >>> 0, 0); b.writeUInt32BE(i, 12); return layout === 'blob' ? b : `${(Math.imul(i,2654435761)>>>0).toString(16).padStart(8,'0')}-0000-4000-8000-${i.toString(16).padStart(12, '0')}`; };
  const hash = Buffer.alloc(32), start = performance.now();
  for (let i = 0; i < n; i += 5000) {
    db.exec('BEGIN IMMEDIATE');
    for (let j = i; j < Math.min(n, i + 5000); j++) { const ms = 1577836800000 + j * 300000; insert.run(key(j), ms, ms, new Date(ms).toISOString().slice(0, 10), hash, Math.floor(j / 5000)); }
    db.exec('COMMIT');
  }
  const insertMs = performance.now() - start;
  const select = db.prepare('SELECT * FROM samples WHERE uuid=?'); const readStart = performance.now();
  for (let i = 0; i < 10000; i++) select.get(key((i * 997) % n));
  const readMs = performance.now() - readStart;
  db.exec('PRAGMA wal_checkpoint(TRUNCATE)'); db.close();
  const row = { name, n, insert_ms: insertMs, samples_per_second: n / insertMs * 1000, lookup_10k_ms: readMs, bytes_per_sample: statSync(path).size / n };
  results.push(row); console.log(row);
}
writeFileSync('bench/results/storage.json', JSON.stringify(results, null, 2) + '\n');
