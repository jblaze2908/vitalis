# Native sync performance harness

Run from `app` with Node 22.23.1:

```sh
npm run bench
BENCH_LABEL=my-change npm run bench
```

Every full run creates a fresh **disk-backed** DB below `app/.data/bench/`; it never uses the production
DB. `/tmp` on the measurement machine is tmpfs and is intentionally avoided. `BENCH_ROOT` overrides
the scratch location. Keep enough free space for each run (the original schema uses about 1.2 GB).
Reports are JSON in `bench/results`. No real health data or credentials are generated or recorded.

The main workload has 201 batches of 5,000 parent upserts (1,005,000 total), with deterministic UUIDs
having random index locality. It sends the touched days' merged daily statistics alongside upserts,
as the phone contract specifies. Fixtures cover:

- 575,000 heart-rate objects, one per five minutes across 5.5 years, including dense 60-point series;
- 375,000 short step/energy intervals from two sources;
- 40,000 sleep segments, 25 per night (1,600 nights);
- one strength batch: 100 workouts with statistics, plus 4,900 HR objects;
- one route batch: ten 45-minute runs, ten 2,700-point routes, plus 4,980 HR objects;
- one cardiac batch: fifty 600-beat series, one 15,000-voltage ECG, plus 4,949 HR objects;
- deletion of the first 5,000 UUIDs and a 5,000-object re-upsert of those permanent tombstones;
- twenty 100-object steady-state batches and a 5,000-object cumulative batch with an overlapping read.

Special payloads mix scalar and bulky objects to stay below the existing 50 MiB wire limit. Parent
objects/s includes route/heartbeat parents; point counts and storage are reported separately.
Synthetic merged daily values model the daily-stat shape; they are not inferred from partial batches.

Wall time surrounds the authenticated Hono request through JSON response consumption, including
parsing, validation, compression, SQLite, projections, and (where enabled) worker transfer/queue time.
Fixture generation/stringification is outside the timer. The maximum interval of a 1 ms timer while
requests run estimates event-loop stalls, including GC and scheduler delays; it is an upper bound on
a single synchronous block. MCP reads use actual authenticated Streamable HTTP tools, not direct
calls to read functions. The 90-day range has data for all three requested scalar metrics; sleep uses
30 populated nights, and workout listing spans the synthetic strength/running dates.

Reported percentiles are observed nearest-rank values. HR/cumulative have 115/75 observations;
sleep has eight; each special 5,000-object shape has one observation. Hot reads have 12 measured
observations after one warmup. Cold start has three fresh processes per DB shape and measures spawn
through a real HTTP `/health` response; OS caches are not flushed. Storage follows a WAL checkpoint,
without VACUUM, and includes table/index page allocations. Packed page allocations by kind are
apportioned by each kind's encoded bytes; original child-table allocations are measured directly.
ECG JSON in the original layout shares sample pages, so only its logical encoded bytes are attributed.

Additional tools:

```sh
node bench/storage-bench.mjs                # seven 1M-row layout/PRAGMA trials
node bench/compression-bench.mjs            # gzip/zstd size + time on five contract shapes
VITALIS_DB=<synthetic.db> node bench/read-latency.mjs
mkdir -p .data/profiles
node --cpu-prof --cpu-prof-dir=.data/profiles bench/profile-ingest.mjs
node bench/summarize-profile.mjs <file.cpuprofile> <summary.json>
node bench/report.mjs --tests=63           # rebuild Markdown + interactive HTML from saved reports
```

`PROFILE_DB` profiles scalar inserts into an existing synthetic DB, `PROFILE_TZ=UTC` exercises named
zones, and `PROFILE_OUTPUT` selects the report. Phase clocks are opt-in via `VITALIS_PROFILE` and
separate parse/envelope, object validation, canonical hashing, compression, SQLite, derivations,
and remaining JS. Derivations include their SQL; it is subtracted from the separate SQLite total.
CPU profiling is run separately from the published end-to-end timings. `BENCH_BATCHES` is a quick
iteration option; runs below 1M parents must not be presented as full backfill results.
