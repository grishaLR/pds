#!/bin/bash
# entrypoint.sh — Generates dynamic litestream config and starts PDS.
#
# Litestream continuously replicates SQLite WAL changes to R2. The base DBs
# (account, sequencer, did_cache) are always included. At startup we scan for
# per-actor store.sqlite files and add them too.
#
# NOTE: Litestream does NOT support config hot-reload (SIGHUP kills it).
# Actors created after startup are covered by actor-backup.sh (periodic
# sqlite3 snapshots) until the next container restart picks them up in
# the litestream config.

set -euo pipefail

ACTORS_DIR="/pds/actors"
CONFIG="/etc/litestream.yml"
BASE_CONFIG="/etc/litestream-base.yml"
PDS_CMD="node --enable-source-maps index.js"

# ── Generate litestream config ────────────────────────────────────────────────

generate_config() {
  # Start with base config (account, sequencer, did_cache)
  cp "$BASE_CONFIG" "$CONFIG"

  [ -d "$ACTORS_DIR" ] || return 0

  local count=0
  for db in "$ACTORS_DIR"/*/*/store.sqlite; do
    [ -f "$db" ] || continue

    # e.g. /pds/actors/5b/did:plc:abc123/store.sqlite → actors/5b/did:plc:abc123
    local rel="${db#/pds/}"                   # actors/5b/did:plc:abc123/store.sqlite
    local r2_path="${rel%/store.sqlite}"       # actors/5b/did:plc:abc123

    cat >> "$CONFIG" <<ENTRY

  - path: ${db}
    replicas:
      - type: s3
        endpoint: \${LITESTREAM_R2_ENDPOINT}
        bucket: protoimsg-pds-backup
        path: ${r2_path}/store.sqlite
        access-key-id: \${LITESTREAM_ACCESS_KEY_ID}
        secret-access-key: \${LITESTREAM_SECRET_ACCESS_KEY}
        sync-interval: 60s
ENTRY
    count=$((count + 1))
  done

  echo "[entrypoint] Litestream config generated with $count actor database(s)"
}

# ── Main ──────────────────────────────────────────────────────────────────────

if [ -z "${LITESTREAM_ACCESS_KEY_ID:-}" ]; then
  echo "[entrypoint] No R2 credentials — running PDS without backup"
  exec $PDS_CMD
fi

generate_config

# Key backup runs in background; trapped for clean shutdown
actor-backup.sh &

exec litestream replicate -exec "$PDS_CMD"
