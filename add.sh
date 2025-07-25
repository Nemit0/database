#!/usr/bin/env bash
# =====================================================================
# add.sh – Restore the three databases from a dump directory
# Usage: ./add.sh _db_dumps/20250724_064720
# =====================================================================
set -Eeuo pipefail

SRC="${1:-}"
[[ -z "$SRC" ]] && { echo "Usage: $0 PATH_TO_DUMP_DIR"; exit 1; }

# ---------- creds ------------------------------------------------------
[[ -f "mysql/.env"                     ]] && source mysql/.env
[[ -f "mongodb/.env"                   ]] && source mongodb/.env
[[ -f "service-container/backend/.env" ]] && source service-container/backend/.env || true

: "${MYSQL_ROOT_PASSWORD:=${MYSQL_PASSWORD:-root}}"
: "${MONGO_INITDB_ROOT_USERNAME:=root}"
: "${MONGO_INITDB_ROOT_PASSWORD:=password}"
: "${ES_USER:=elastic}"
: "${ES_PASS:=mangoberry}"
: "${ES_HOST:=http://localhost:9200}"
ES_REPO_NAME="fs_backup"
ES_SNAP_PATH="/usr/share/elasticsearch/snapshots"

MYSQL_DUMP="${SRC}/mysql/all.sql"
MONGO_ARCHIVE="${SRC}/mongodb/mongo.archive.gz"
ES_SNAP_LOCAL="${SRC}/elasticsearch/snapshots"

if command -v docker-compose >/dev/null 2>&1; then DC="docker-compose"; else DC="docker compose"; fi

abort(){ echo "ERROR: $*" >&2; exit 1; }
need_f(){ [[ -f "$1" ]] || abort "Missing file: $1"; }
need_d(){ [[ -d "$1" ]] || abort "Missing dir: $1"; }
need_c(){ docker ps --format '{{.Names}}' | grep -qx "$1" || abort "Container '$1' not running."; }

echo "=> Validating dump..."
need_f "$MYSQL_DUMP"
need_f "$MONGO_ARCHIVE"
need_d "$ES_SNAP_LOCAL"

echo "=> Ensuring DB containers are live..."
need_c mysql
need_c mongodb
need_c elasticsearch

# ------------------ MySQL ---------------------------------------------
echo "=> Restoring MySQL..."
docker exec -i -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql \
  mysql -uroot < "$MYSQL_DUMP"

# ------------------ MongoDB -------------------------------------------
echo "=> Restoring MongoDB..."
gunzip -c "$MONGO_ARCHIVE" | docker exec -i mongodb \
  mongorestore --archive \
               --username "$MONGO_INITDB_ROOT_USERNAME" \
               --password "$MONGO_INITDB_ROOT_PASSWORD" \
               --authenticationDatabase admin

# ------------------ Elasticsearch -------------------------------------
echo "=> Restoring Elasticsearch snapshot..."
docker exec -u 0 elasticsearch bash -c "mkdir -p ${ES_SNAP_PATH} && chown -R elasticsearch:elasticsearch ${ES_SNAP_PATH}"
docker cp "$ES_SNAP_LOCAL/." elasticsearch:${ES_SNAP_PATH}/

curl -fsS -u "${ES_USER}:${ES_PASS}" -H 'Content-Type: application/json' \
  -X PUT "${ES_HOST}/_snapshot/${ES_REPO_NAME}" \
  -d "{\"type\":\"fs\",\"settings\":{\"location\":\"${ES_SNAP_PATH}\",\"compress\":true}}" \
  >/dev/null || true

# auto-detect snapshot name
SNAP_NAME="$(docker exec elasticsearch bash -c "ls ${ES_SNAP_PATH}" | grep -E '^full_' | head -n1)"
[[ -z "$SNAP_NAME" ]] && abort "No 'full_' snapshot found inside container."

RESP=$(curl -fsS -u "${ES_USER}:${ES_PASS}" -H 'Content-Type: application/json' \
  -X POST "${ES_HOST}/_snapshot/${ES_REPO_NAME}/${SNAP_NAME}/_restore?wait_for_completion=true" \
  -d '{
    "indices": "*,-.internal.*,-.security*,-.kibana*,-.fleet*",
    "ignore_unavailable": true,
    "include_global_state": false
  }')
echo "$RESP" | grep -qi '"accepted":true\|"type":"completed"\|"state":"SUCCESS"' || { echo "$RESP"; abort "Restore failed."; }

echo "✅ Restore complete from: $SRC"
