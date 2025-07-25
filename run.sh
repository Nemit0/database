set -euo pipefail

# ────────────────────────────── config ──────────────────────────────
BRANCH="main"

# required directories -> uid:gid
declare -A REQ_DIRS=(
  ["elasticsearch/data"]="1000:0"
  ["elasticsearch/snapshots"]="1000:0"
  ["mongodb/config"]="0:0"
  ["mongodb/data"]="0:0"
  ["mongodb/initdb"]="0:0"
  ["mysql/conf.d"]="0:0"
  ["mysql/data"]="0:0"
  ["mysql/initdb"]="0:0"
)

# ───────────────────────────── args/env ─────────────────────────────
RESTORE_SRC="${RESTORE_ES_FROM:-}"   # can be set via env
if [[ "${1:-}" == "--restore" ]]; then
  shift
  RESTORE_SRC="${1:-}"
  shift || true
fi

REAL_USER="${SUDO_USER-$(whoami)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

step() { printf "\n\033[1;34m[•] %s\033[0m\n" "$*"; }
ok()   { printf "\033[1;32m[✓]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[!]\033[0m %s\n" "$*"; }
die()  { printf "\033[1;31m[✗]\033[0m %s\n" "$*" >&2; exit 1; }

ensure_dirs_and_perms() {
  step "Checking folders and fixing ownerships"
  for path in "${!REQ_DIRS[@]}"; do
    abs="$SCRIPT_DIR/$path"
    owner="${REQ_DIRS[$path]}"
    if [[ ! -d "$abs" ]]; then
      echo "Creating $abs"
      mkdir -p "$abs"
    fi
    current_uid=$(stat -c '%u' "$abs")
    current_gid=$(stat -c '%g' "$abs")
    target_uid="${owner%%:*}"
    target_gid="${owner##*:}"
    if [[ "$current_uid" != "$target_uid" || "$current_gid" != "$target_gid" ]]; then
      echo "chown $owner $path"
      chown -R "$owner" "$abs"
    fi
  done
  ok "All required directories exist with correct owners"
}

git_pull_as_real_user() {
  step "Pulling latest code from '$BRANCH'"
  if [[ "$(whoami)" == "root" && "$REAL_USER" != "root" ]]; then
    sudo -u "$REAL_USER" git pull origin "$BRANCH"
  else
    git pull origin "$BRANCH"
  fi
  ok "Repo updated"
}

tune_kernel_for_es() {
  if command -v sysctl >/dev/null 2>&1; then
    step "Ensuring vm.max_map_count ≥ 262144"
    current=$(sysctl -n vm.max_map_count || echo 0)
    if [[ "$current" -lt 262144 ]]; then
      sysctl -w vm.max_map_count=262144 >/dev/null
      ok "vm.max_map_count set to 262144"
    else
      ok "vm.max_map_count already sufficient ($current)"
    fi
  fi
}

restore_elasticsearch_if_requested() {
  [[ -z "$RESTORE_SRC" ]] && return 0

  # Validate path
  if [[ ! -d "$RESTORE_SRC/elasticsearch/snapshots" ]]; then
    die "Restore dir '$RESTORE_SRC' does not look valid (missing elasticsearch/snapshots)."
  fi

  step "Restoring Elasticsearch from $RESTORE_SRC"
  # Run the helper; it waits for ES and handles clashes
  "$SCRIPT_DIR/es_restore.sh" "$RESTORE_SRC/elasticsearch/snapshots"
  ok "ES restore completed"
}

# ────────────────────────────── main ────────────────────────────────
step "Stopping any running containers"
docker compose down

ensure_dirs_and_perms
git_pull_as_real_user
tune_kernel_for_es

if [[ -n "$RESTORE_SRC" ]]; then
  # Start only DB services first, keep Kibana off until restore is done
  step "Building and starting DB containers (ES/MySQL/Mongo)"
  docker compose up --build -d mysql mongodb elasticsearch

  restore_elasticsearch_if_requested

  step "Starting remaining services (e.g., Kibana)"
  docker compose up -d kibana
else
  step "Building and starting all containers"
  docker compose up --build -d
fi

ok "Deployment complete ✅"