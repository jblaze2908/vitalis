# Vitalis

A self-hosted health ledger for your agents. Vitalis takes Apple Health data from your iPhone and keeps a strength-training log the Apple Watch can't. Any agent can then ask, over MCP, "how did I sleep, should I train hard today, what did I bench last time". Every answer is measured against your own normal, not a population average.

One instance serves one person. Your health data stays on your server.

## What it does

- **Collects** Apple Health data that [Health Auto Export](https://apps.apple.com/app/id1115567069) pushes from the phone: sleep with stages, resting heart rate, HRV, breathing, SpO₂, wrist temperature, steps, energy, weight, and Watch workouts. Every push is stored raw before parsing, re-sends are harmless, and a bad metric never fails a push.
- **Logs strength training**: sets with weight, reps, kind (warm-up, normal, drop, failure), RPE and targets. Sessions form on their own, and retries are safe. It ships a catalogue of about 750 public-domain exercises, with gym shorthand such as "bench", "ohp" and "rdl".
- **Compares you with yourself.** Each value comes with your usual (the median of the 30 days before) and a usual range, and is flagged when it falls outside. Bedtimes either side of midnight are handled. There is no composite score: every call shows its inputs and its rule.
- **Serves agents** through 13 MCP tools: a morning brief, sleep, metric trends, workouts, exercise history with a next-session suggestion, training summaries, exercise search, freshness, and four write tools for the training log. A missing day is reported as missing, never as zero.

## Architecture

| Part | What |
|---|---|
| `app/src` | Node 22, TypeScript, Hono, `node:sqlite`, the official MCP TypeScript SDK. One process serves `/ingest`, `/mcp` and `/health`. |
| `app/data/exercises.json` | Exercise catalogue from [free-exercise-db](https://github.com/yuhonas/free-exercise-db) (Unlicense). |
| `deploy/` | Docker Compose: a read-only container, loopback port, one data directory. |
| `docs/` | [`api.md`](docs/api.md) is the contract: ingest, every tool, and the day, baseline and freshness rules. [`deploy.md`](docs/deploy.md) covers self-hosting. |

There is no web UI. You use it through agents, and administer it through the CLI.

## Quickstart (local)

```sh
cd app && npm ci && npm run build && npm test
VITALIS_ROOT=../.data VITALIS_TZ=Asia/Kolkata npm start            # http://127.0.0.1:8350
VITALIS_ROOT=../.data npm run cli -- token create me --scope write
```

## Self-host

See **[docs/deploy.md](docs/deploy.md)**.

## License

[MIT](LICENSE)
