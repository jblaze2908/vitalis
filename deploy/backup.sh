#!/usr/bin/env bash
# A consistent copy of the SQLite file (VACUUM INTO), made with the app's own image so the host needs no sqlite3.
# scale0 runs it before each deploy; it's also fine from cron. Keeps the newest 14 copies in DEST.
set -Eeuo pipefail
DATA="${VITALIS_DATA:-/srv/vitalis}"
DEST="${DEST:-/var/backups/vitalis}"
IMAGE="${IMAGE:-vitalis-app:${VITALIS_TAG:-local}}"
[[ -f "$DATA/vitalis.db" ]] || { echo "no database yet, nothing to back up"; exit 0; }
install -d -m 700 "$DEST"
snap="$DATA/.backup-$$.db"
trap 'rm -f "$snap"' EXIT
docker run --rm --network none --user "$(stat -c %u:%g "$DATA")" -v "$DATA:$DATA" --entrypoint node "$IMAGE" \
  -e "new (require('node:sqlite').DatabaseSync)(process.argv[1]).exec(\"VACUUM INTO '\" + process.argv[2] + \"'\")" "$DATA/vitalis.db" "$snap"
out="$DEST/pre-$(date -u +%Y%m%dT%H%M%SZ).db"
mv "$snap" "$out" && chmod 600 "$out"
ls -1t "$DEST"/pre-*.db | tail -n +15 | xargs -r rm -f
echo "backup $(basename "$out"): $(du -k "$out" | cut -f1) KB"
