#!/bin/bash
# actor-backup.sh — Periodic backup of actor signing keys and new actor DBs to R2.
#
# Litestream handles continuous SQLite replication for actor store.sqlite files
# that existed at startup. This script covers:
#   1. Signing keys (non-SQLite, litestream can't handle them)
#   2. Actors created AFTER startup (not yet in litestream config — covered
#      by periodic sqlite3 .backup snapshots until next container restart)

set -euo pipefail

ACTORS_DIR="/pds/actors"
TRACKED_KEYS="/tmp/backed-up-keys"
TRACKED_DBS="/tmp/backed-up-dbs"
INTERVAL_SECONDS=300  # 5 minutes

# Clean shutdown on SIGTERM (container stop/deploy)
SLEEP_PID=
trap 'echo "[actor-backup] Shutting down"; [ -n "$SLEEP_PID" ] && kill "$SLEEP_PID" 2>/dev/null; exit 0' SIGTERM SIGINT

# If R2 credentials aren't set, exit silently
if [ -z "${LITESTREAM_ACCESS_KEY_ID:-}" ] || [ -z "${LITESTREAM_R2_ENDPOINT:-}" ]; then
  echo "[actor-backup] No R2 credentials configured, skipping"
  exit 0
fi

# Configure rclone for R2 (restricted permissions)
export RCLONE_CONFIG=/tmp/rclone.conf
install -m 600 /dev/null "$RCLONE_CONFIG"
cat > "$RCLONE_CONFIG" <<EOF
[r2]
type = s3
provider = Cloudflare
access_key_id = ${LITESTREAM_ACCESS_KEY_ID}
secret_access_key = ${LITESTREAM_SECRET_ACCESS_KEY}
endpoint = ${LITESTREAM_R2_ENDPOINT}
no_check_bucket = true
EOF

touch "$TRACKED_KEYS" "$TRACKED_DBS"

# Snapshot the litestream-managed DB list at startup so we know which actors
# were picked up by entrypoint.sh. Anything NOT in this list is "new."
LITESTREAM_DBS="/tmp/litestream-actor-dbs"
find "$ACTORS_DIR" -name "store.sqlite" 2>/dev/null > "$LITESTREAM_DBS" || true

backup_keys() {
  [ -d "$ACTORS_DIR" ] || return 0

  local count=0
  for keyfile in "$ACTORS_DIR"/*/*/key; do
    [ -f "$keyfile" ] || continue

    # Skip if already backed up
    if grep -qxF "$keyfile" "$TRACKED_KEYS" 2>/dev/null; then
      continue
    fi

    # e.g. /pds/actors/5b/did:plc:abc123/key → actors/5b/did:plc:abc123/key
    local r2_path="${keyfile#/pds/}"

    if rclone copyto "$keyfile" "r2:protoimsg-pds-backup/${r2_path}" --quiet 2>/dev/null; then
      echo "$keyfile" >> "$TRACKED_KEYS"
      count=$((count + 1))
    else
      echo "[actor-backup] Warning: failed to upload $keyfile"
    fi
  done

  [ "$count" -gt 0 ] && echo "[actor-backup] Uploaded $count new signing key(s) to R2"
}

backup_new_actor_dbs() {
  # Snapshot actor DBs that were created AFTER entrypoint.sh ran (not in litestream)
  [ -d "$ACTORS_DIR" ] || return 0

  local count=0
  for db in "$ACTORS_DIR"/*/*/store.sqlite; do
    [ -f "$db" ] || continue

    # Skip if litestream already handles this one
    if grep -qxF "$db" "$LITESTREAM_DBS" 2>/dev/null; then
      continue
    fi

    # Skip if we already backed it up recently
    if grep -qxF "$db" "$TRACKED_DBS" 2>/dev/null; then
      continue
    fi

    local rel="${db#/pds/}"
    local r2_path="${rel%/store.sqlite}"
    local snapshot="/tmp/actor-db-snapshot.sqlite"

    # sqlite3 .backup creates a consistent snapshot (handles WAL)
    if sqlite3 "$db" ".backup '$snapshot'" 2>/dev/null; then
      if rclone copyto "$snapshot" "r2:protoimsg-pds-backup/${r2_path}/store.sqlite" --quiet 2>/dev/null; then
        echo "$db" >> "$TRACKED_DBS"
        count=$((count + 1))
      else
        echo "[actor-backup] Warning: failed to upload snapshot for $db"
      fi
      rm -f "$snapshot"
    else
      echo "[actor-backup] Warning: failed to snapshot $db"
    fi
  done

  [ "$count" -gt 0 ] && echo "[actor-backup] Snapshot-backed $count new actor database(s) to R2"
}

echo "[actor-backup] Starting periodic backup (every ${INTERVAL_SECONDS}s)"

# Run immediately on startup, then loop
backup_keys || echo "[actor-backup] Initial key backup failed, will retry"

while true; do
  sleep "$INTERVAL_SECONDS" &
  SLEEP_PID=$!
  wait "$SLEEP_PID" 2>/dev/null || break
  SLEEP_PID=
  backup_keys || echo "[actor-backup] Key backup failed, will retry"
  backup_new_actor_dbs || echo "[actor-backup] DB snapshot failed, will retry"
done
