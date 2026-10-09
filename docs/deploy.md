# Deploying Vitalis

Vitalis is one container with one SQLite file. Any machine with Docker can run it: a home server, a VPS, a laptop.

## Requirements

- Docker with the compose plugin.
- A reverse proxy with TLS (Caddy, nginx or Traefik) for a hostname you own. The phone pushes over the internet, so the proxy must be reachable from it.
- On the iPhone: Health Auto Export, with its Premium tier for automations.

## Steps

```sh
git clone <repo-url> /opt/vitalis
install -d -m 700 /etc/vitalis
cp /opt/vitalis/.env.example /etc/vitalis/vitalis.env && chmod 600 /etc/vitalis/vitalis.env
$EDITOR /etc/vitalis/vitalis.env                 # VITALIS_HOST and VITALIS_TZ at least
install -d -o 1650 -g 1650 -m 700 /srv/vitalis
docker compose -f /opt/vitalis/deploy/compose.yml up -d --build
```

The image build runs the test suite. A failing test fails the build.

## Reverse proxy

Forward `https://<VITALIS_HOST>` to `127.0.0.1:8350`. Caddy:

```
vitalis.example.com {
  reverse_proxy 127.0.0.1:8350
}
```

nginx: `proxy_pass http://127.0.0.1:8350;` and `client_max_body_size 50m;` for backfills.

## Tokens

```sh
docker exec vitalis-app node dist/src/cli.js token create iphone --scope ingest
docker exec vitalis-app node dist/src/cli.js token create claude-code --scope write
docker exec vitalis-app node dist/src/cli.js token create assistant --scope read
```

Each token is shown once. Revoke one with `token revoke <name>`.

## Phone

In Health Auto Export, create an automation:
- **REST API**, URL `https://<VITALIS_HOST>/ingest`
- header `Authorization: Bearer <ingest token>`
- JSON, Export Version 2
- Time Grouping Day, Summarize Data on
- Since Last Sync, Batch Requests on

Add Health Metrics and Workouts. Run it once by hand, then check `vitalis syncs`.

iOS doesn't let any app read health data while the phone is locked, and background runs aren't guaranteed. Expect pushes when the phone is unlocked. `get_freshness` shows the gaps.

**Backfill:** in Health Auto Export, do a manual export with JSON, Version 2, Time Grouping Day and a custom date range, then copy the file to the server:

```sh
docker cp export.json vitalis-app:/tmp/ && docker exec vitalis-app node dist/src/cli.js import /tmp/export.json
```

## Agents

Any MCP client that sends a bearer header works. Claude Code:

```sh
claude mcp add --transport http vitalis https://<VITALIS_HOST>/mcp --header "Authorization: Bearer <read or write token>"
```

If you run [Engram](https://github.com/jblaze2908/engram), add Vitalis there once as an upstream with a bearer token instead. Every agent then reaches it as `vitalis__<tool>`, under Engram's per-agent grants.

## Backups

Everything is in `/srv/vitalis/vitalis.db`. Back up with SQLite's online copy:

```sh
sqlite3 /srv/vitalis/vitalis.db ".backup /var/backups/vitalis-$(date +%F).db"
```

Run it from cron or a systemd timer, and ship the copy off the machine (restic, rclone). Raw pushes are kept in the database too, so a restore can also re-parse.

## Updates

```sh
cd /opt/vitalis && git pull && docker compose -f deploy/compose.yml up -d --build
```

The schema is created and extended at start-up. There are no separate migrations to run.
