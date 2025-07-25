#!/usr/bin/env bash
# =====================================================================
# dump.sh – Dump MySQL, MongoDB and Elasticsearch into one timestamped dir
# =====================================================================
set -Eeuo pipefail

# ---------------- user-tweakable --------------------------------------
BACKUP_ROOT="_db_dumps"             # where to store backups
ES_REPO_NAME="fs_backup"            # ES repo name
ES_SNAPSHOT_PREFIX="full"           # prefix for snapshot file
ES_SNAP_PATH="/usr/share/elasticsearch/snapshots"  # inside container

# ----------- load credentials if available ----------------------------
[[ -f "mysql/.env"                     ]] && source mysql/.env
[[ -f "mongodb/.env"                   ]] && source mongodb/.env
[[ -f "service-container/backend/.env" ]] && source service-container/backend/.env || true

: "${MYSQL_ROOT_PASSWORD:=${MYSQL_PASSWORD:-root}}"
: "${MONGO_INITDB_ROOT_USERNAME:=root}"
: "${MONGO_INITDB_ROOT_PASSWORD:=password}"
: "${ES_USER:=elastic}"
: "${ES_PASS:=mangoberry}"
: "${ES_HOST:=http://localhost:9200}"

# docker compose shim
if command -v docker-compose >/dev/null 2>&1; then DC="docker-compose"; else DC="docker compose"; fi

timestamp="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="${BACKUP_ROOT}/${timestamp}"
MYSQL_DUMP="${OUT_DIR}/mysql/all.sql"
MONGO_ARCHIVE="${OUT_DIR}/mongodb/mongo.archive.gz"
ES_DIR="${OUT_DIR}/elasticsearch"
ES_SNAP_LOCAL="${ES_DIR}/snapshots"

abort(){ echo "ERROR: $*" >&2; exit 1; }
need_container(){ docker ps --format '{{.Names}}' | grep -qx "$1" || abort "Container '$1' not running."; }

echo "=> Preparing ${OUT_DIR}"
mkdir -p "${OUT_DIR}/"{mysql,mongodb,elasticsearch}

echo "=> Verifying containers..."
need_container mysql
need_container mongodb
need_container elasticsearch

# ---------------------- MySQL -----------------------------------------
echo "=> MySQL dump..."
mkdir -p "$(dirname "$MYSQL_DUMP")"
docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql \
  mysqldump --all-databases --single-transaction --routines --events --triggers -uroot \
  > "$MYSQL_DUMP"

# ---------------------- MongoDB ---------------------------------------
echo "=> MongoDB dump..."
mkdir -p "$(dirname "$MONGO_ARCHIVE")"
docker exec mongodb bash -c "
  mongodump \
    --username '${MONGO_INITDB_ROOT_USERNAME}' \
    --password '${MONGO_INITDB_ROOT_PASSWORD}' \
    --authenticationDatabase admin \
    --archive" \
| gzip > "$MONGO_ARCHIVE"

# ---------------------- Elasticsearch ---------------------------------
echo "=> Elasticsearch snapshot..."
# Ensure repo dir exists and is writable by ES user
docker exec -u 0 elasticsearch bash -c "mkdir -p ${ES_SNAP_PATH} && chown -R elasticsearch:elasticsearch ${ES_SNAP_PATH}"

# Register repo (idempotent)
curl -fsS -u "${ES_USER}:${ES_PASS}" -H 'Content-Type: application/json' \
  -X PUT "${ES_HOST}/_snapshot/${ES_REPO_NAME}" \
  -d "{\"type\":\"fs\",\"settings\":{\"location\":\"${ES_SNAP_PATH}\",\"compress\":true}}" \
  >/dev/null || true

SNAP_NAME="${ES_SNAPSHOT_PREFIX}_${timestamp}"

# Trigger snapshot and capture response
RESP=$(curl -fsS -u "${ES_USER}:${ES_PASS}" -H 'Content-Type: application/json' \
  -X PUT "${ES_HOST}/_snapshot/${ES_REPO_NAME}/${SNAP_NAME}?wait_for_completion=true" \
  -d '{"indices":"*","ignore_unavailable":true,"include_global_state":true}')
echo "$RESP" | grep -qi '"state":"SUCCESS"' || { echo "$RESP"; abort "Snapshot failed."; }

# Copy files out if not bind-mounted
mkdir -p "$ES_SNAP_LOCAL"
if ! mountpoint -q elasticsearch/snapshots 2>/dev/null; then
  docker cp "elasticsearch:${ES_SNAP_PATH}/." "$ES_SNAP_LOCAL/"
else
  # bind-mounted case: just copy from host path
  cp -a elasticsearch/snapshots/. "$ES_SNAP_LOCAL/"
fi

echo "✅ Dump finished → $OUT_DIR"
echo "Next: rsync/scp that folder then run:  ./add.sh  $OUT_DIR"
