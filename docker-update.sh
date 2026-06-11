#!/usr/bin/env bash
# =============================================================================
# docker-update.sh
# Iterates over each subdirectory of the compose root, checks whether the
# compose project is running, pulls fresh images, and restarts the project
# only when at least one image was actually updated.
#
# Requires Docker Compose v2 (plugin or standalone).
# =============================================================================

set -euo pipefail
shopt -s nullglob

COMPOSE_ROOT="${COMPOSE_ROOT:-/volume2/docker}"
LOG_PREFIX="[docker-update]"
SKIP_MARKER=".no-update"
LOCK_FILE="${TMPDIR:-/tmp}/docker-update.lock"
SETTLE_SECONDS="${SETTLE_SECONDS:-5}"
DRY_RUN=false

usage() {
  cat <<EOF
Usage: ${0##*/} [OPTIONS]

Pulls fresh images for every running Docker Compose project under the compose
root and restarts only the projects where an image actually changed.

Options:
  --root DIR    Compose root to scan (default: ${COMPOSE_ROOT},
                also settable via the COMPOSE_ROOT environment variable)
  --dry-run     Pull images and report what would be restarted, but do not
                restart anything or prune images
  -h, --help    Show this help and exit

A project directory is skipped when it contains a file named '${SKIP_MARKER}'.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true ;;
    --root)
      [[ $# -ge 2 ]] || { echo "${LOG_PREFIX} --root requires a directory argument" >&2; exit 2; }
      COMPOSE_ROOT="$2"; shift ;;
    --root=*) COMPOSE_ROOT="${1#--root=}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "${LOG_PREFIX} unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# Colour helpers (disabled when not a TTY or NO_COLOR is set); timestamps are
# added when output is not a TTY so cron logs are easy to follow.
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; RESET=''
fi
if [[ -t 1 ]]; then
  ts() { :; }
else
  ts() { date '+%Y-%m-%dT%H:%M:%S '; }
fi

log()  { printf '%s%b%s%b %s\n' "$(ts)" "$CYAN"   "$LOG_PREFIX"   "$RESET" "$*"; }
ok()   { printf '%s%b%s ✔%b %s\n' "$(ts)" "$GREEN"  "$LOG_PREFIX" "$RESET" "$*"; }
warn() { printf '%s%b%s ⚠%b %s\n' "$(ts)" "$YELLOW" "$LOG_PREFIX" "$RESET" "$*"; }
err()  { printf '%s%b%s ✖%b %s\n' "$(ts)" "$RED"    "$LOG_PREFIX" "$RESET" "$*" >&2; }

# ---------------------------------------------------------------------------
# Prevent overlapping runs (e.g. a manual run colliding with cron)
# ---------------------------------------------------------------------------
if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    err "Another docker-update run is already in progress (lock: ${LOCK_FILE})."
    exit 1
  fi
else
  warn "flock not available — cannot guard against concurrent runs."
fi

# ---------------------------------------------------------------------------
# Resolve docker privilege (plain, or sudo -n so cron never hangs on a
# password prompt) and the compose invocation (plugin vs standalone).
# ---------------------------------------------------------------------------
if docker info >/dev/null 2>&1; then
  DOCKER=(docker)
elif command -v sudo >/dev/null 2>&1 && sudo -n docker info >/dev/null 2>&1; then
  DOCKER=(sudo -n docker)
else
  err "Cannot talk to the Docker daemon (tried 'docker' and 'sudo -n docker')."
  err "Run as root, add this user to the docker group, or allow passwordless sudo."
  exit 1
fi

if "${DOCKER[@]}" compose version >/dev/null 2>&1; then
  COMPOSE=("${DOCKER[@]}" compose)
elif command -v docker-compose >/dev/null 2>&1; then
  if [[ "${DOCKER[0]}" == sudo ]]; then
    COMPOSE=(sudo -n docker-compose)
  else
    COMPOSE=(docker-compose)
  fi
else
  err "Neither 'docker compose' (plugin) nor 'docker-compose' (standalone) found."
  exit 1
fi

if [[ ! -d "$COMPOSE_ROOT" ]]; then
  err "Compose root '${COMPOSE_ROOT}' does not exist or is not a directory."
  exit 1
fi

log "Using compose command: ${COMPOSE[*]}"
log "Scanning ${COMPOSE_ROOT}"
[[ "$DRY_RUN" == true ]] && warn "Dry-run mode: no projects will be restarted."
echo

# Run compose from inside the project directory (no -f) so override files
# (docker-compose.override.yml) and .env are honoured exactly as they would
# be when running compose by hand.
compose() {
  ( cd "$project_dir" && "${COMPOSE[@]}" "$@" )
}

# Print every service listed in $1 (newline-separated) missing from $2.
missing_services() {
  local svc
  while IFS= read -r svc; do
    [[ -z "$svc" ]] && continue
    grep -Fxq "$svc" <<<"$2" || printf '%s\n' "$svc"
  done <<<"$1"
}

running_services() {
  compose ps --status running --services 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
updated_projects=()
skipped_projects=()
failed_projects=()

for project_dir in "${COMPOSE_ROOT}"/*/; do
  [[ -d "$project_dir" ]] || continue

  project_name=$(basename "$project_dir")

  if [[ -e "${project_dir}${SKIP_MARKER}" ]]; then
    warn "${project_name}: '${SKIP_MARKER}' marker present, skipping."
    skipped_projects+=("${project_name} (marked ${SKIP_MARKER})")
    continue
  fi

  # Locate a compose file (supports all standard names)
  compose_file=""
  for candidate in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
    if [[ -f "${project_dir}${candidate}" ]]; then
      compose_file="${project_dir}${candidate}"
      break
    fi
  done

  if [[ -z "$compose_file" ]]; then
    warn "${project_name}: no compose file found, skipping."
    skipped_projects+=("${project_name} (no compose file)")
    continue
  fi

  log "--- ${project_name} (${project_dir}) ---"

  # -------------------------------------------------------------------------
  # Check whether the project has at least one running container. A failing
  # 'compose ps' is a project failure, not the same as "nothing running".
  # -------------------------------------------------------------------------
  if ! ps_output=$(compose ps --status running --quiet 2>&1); then
    err "${project_name}: 'compose ps' failed:"
    printf '%s\n' "$ps_output" | tail -n 3 >&2
    failed_projects+=("${project_name}")
    echo
    continue
  fi

  running_ids=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && running_ids+=("$line")
  done <<<"$ps_output"

  if [[ ${#running_ids[@]} -eq 0 ]]; then
    warn "${project_name}: no running containers — skipping pull."
    skipped_projects+=("${project_name} (not running)")
    echo
    continue
  fi

  log "${project_name}: ${#running_ids[@]} running container(s) detected."
  services_before=$(running_services)

  # -------------------------------------------------------------------------
  # Pull images
  # -------------------------------------------------------------------------
  if ! pull_output=$(compose pull 2>&1); then
    err "${project_name}: 'compose pull' failed — skipping restart. Last output:"
    printf '%s\n' "$pull_output" | tail -n 5 >&2
    failed_projects+=("${project_name}")
    echo
    continue
  fi

  # -------------------------------------------------------------------------
  # Detect updates by comparing each running container's image ID against the
  # now-current local image for its tag. This is exact (no parsing of pull
  # output) and also catches images shared between projects, where the second
  # project's pull is a no-op but its containers still run the old image.
  # -------------------------------------------------------------------------
  update_detected=false
  for container_id in "${running_ids[@]}"; do
    container_image_id=$("${DOCKER[@]}" inspect --format '{{.Image}}' "$container_id" 2>/dev/null) || continue
    image_name=$("${DOCKER[@]}" inspect --format '{{.Config.Image}}' "$container_id" 2>/dev/null) || continue
    current_image_id=$("${DOCKER[@]}" image inspect --format '{{.Id}}' "$image_name" 2>/dev/null) || continue
    if [[ -n "$current_image_id" && "$container_image_id" != "$current_image_id" ]]; then
      update_detected=true
      break
    fi
  done

  if [[ "$update_detected" == false ]]; then
    log "${project_name}: all images already up to date — no restart needed."
    skipped_projects+=("${project_name} (already up to date)")
    echo
    continue
  fi

  if [[ "$DRY_RUN" == true ]]; then
    ok "${project_name}: new image(s) found — would restart (dry-run)."
    updated_projects+=("${project_name} (dry-run, not restarted)")
    echo
    continue
  fi

  # -------------------------------------------------------------------------
  # Restart: 'up -d' recreates only the containers whose configuration or
  # image changed (and their dependents, e.g. network_mode: service: sidecars)
  # — far less downtime than a full down/up, and a failed start cannot take
  # the whole project offline.
  # -------------------------------------------------------------------------
  ok "${project_name}: new image(s) found — updating project."

  if ! compose up -d --remove-orphans; then
    err "${project_name}: 'compose up' failed."
    failed_projects+=("${project_name}")
    echo
    continue
  fi

  # Verify every service that was running before is running again; if not,
  # fall back to a full down/up (covers dependency patterns compose cannot
  # track, e.g. network_mode: container:<name>).
  sleep "$SETTLE_SECONDS"
  missing=$(missing_services "$services_before" "$(running_services)")
  if [[ -n "$missing" ]]; then
    warn "${project_name}: not running after 'up -d': ${missing//$'\n'/ } — trying full down/up."
    if ! compose down || ! compose up -d; then
      err "${project_name}: full restart failed."
      failed_projects+=("${project_name}")
      echo
      continue
    fi
    sleep "$SETTLE_SECONDS"
    missing=$(missing_services "$services_before" "$(running_services)")
    if [[ -n "$missing" ]]; then
      err "${project_name}: still not running after full restart: ${missing//$'\n'/ }"
      failed_projects+=("${project_name}")
      echo
      continue
    fi
  fi

  ok "${project_name}: updated and restarted successfully."
  updated_projects+=("${project_name}")
  echo
done

# ---------------------------------------------------------------------------
# Prune dangling images left behind by updates
# ---------------------------------------------------------------------------
if [[ "$DRY_RUN" == false && ${#updated_projects[@]} -gt 0 ]]; then
  log "Pruning dangling images..."
  "${DOCKER[@]}" image prune -f >/dev/null 2>&1 || warn "image prune failed (non-fatal)."
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '%b====== Summary ======%b\n' "$BOLD" "$RESET"

if [[ ${#updated_projects[@]} -gt 0 ]]; then
  ok "Updated (${#updated_projects[@]}):"
  for p in "${updated_projects[@]}"; do printf '    • %s\n' "$p"; done
fi

if [[ ${#skipped_projects[@]} -gt 0 ]]; then
  warn "Skipped (${#skipped_projects[@]}):"
  for p in "${skipped_projects[@]}"; do printf '    • %s\n' "$p"; done
fi

if [[ ${#failed_projects[@]} -gt 0 ]]; then
  err "Failed (${#failed_projects[@]}):"
  for p in "${failed_projects[@]}"; do printf '    • %s\n' "$p"; done
  exit 1
fi

exit 0
