#!/usr/bin/env bash
# =============================================================================
# docker-update.sh
# Iterates over each subdirectory of /volume2/docker/, checks whether the
# compose project is running, pulls fresh images, and restarts the project
# only when at least one image was actually updated.
# =============================================================================

set -euo pipefail

COMPOSE_ROOT="/volume2/docker"
LOG_PREFIX="[docker-update]"

# Colour helpers (disabled automatically when not a TTY)
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; RESET=''
fi

log()  { echo -e "${CYAN}${LOG_PREFIX}${RESET} $*"; }
ok()   { echo -e "${GREEN}${LOG_PREFIX} ✔${RESET} $*"; }
warn() { echo -e "${YELLOW}${LOG_PREFIX} ⚠${RESET} $*"; }
err()  { echo -e "${RED}${LOG_PREFIX} ✖${RESET} $*" >&2; }

# ---------------------------------------------------------------------------
# Resolve the correct docker compose invocation (plugin vs standalone)
# ---------------------------------------------------------------------------
if sudo docker compose version &>/dev/null 2>&1; then
  COMPOSE="sudo docker compose"
elif command -v docker-compose &>/dev/null; then
  COMPOSE="sudo docker-compose"
else
  err "Neither 'docker compose' (plugin) nor 'docker-compose' (standalone) found."
  exit 1
fi

log "Using compose command: ${BOLD}${COMPOSE}${RESET}"
log "Scanning ${BOLD}${COMPOSE_ROOT}${RESET}"
echo

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
updated_projects=()
skipped_projects=()
failed_projects=()

for project_dir in "${COMPOSE_ROOT}"/*/; do
  [[ -d "$project_dir" ]] || continue

  project_name=$(basename "$project_dir")

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

  log "--- ${BOLD}${project_name}${RESET} (${compose_file}) ---"

  # -------------------------------------------------------------------------
  # Check whether the project has at least one running container
  # -------------------------------------------------------------------------
  running_count=$(
    $COMPOSE -f "$compose_file" ps --status running --quiet 2>/dev/null | wc -l
  )

  if [[ "$running_count" -eq 0 ]]; then
    warn "${project_name}: no running containers — skipping pull."
    skipped_projects+=("${project_name} (not running)")
    echo
    continue
  fi

  log "${project_name}: ${running_count} running container(s) detected."

  # -------------------------------------------------------------------------
  # Pull images and detect whether anything was actually updated
  # A pull prints "Pull complete" / "Downloaded newer image" when new layers
  # arrive, and "Image is up to date" / "Status: Image is up to date" when
  # nothing changed. We capture stdout+stderr and search for update markers.
  # -------------------------------------------------------------------------
  pull_output=$(
    $COMPOSE -f "$compose_file" pull 2>&1
  ) || {
    err "${project_name}: 'compose pull' failed — skipping restart."
    failed_projects+=("${project_name}")
    echo
    continue
  }

  # Primary check: pull output contains update markers.
  # Docker prints one of these phrases when a new image is fetched:
  #   "Pull complete"            – individual layer downloaded
  #   "Downloaded newer image"   – digest-level confirmation
  #   "Pulled"                   – newer docker compose plugin wording
  update_detected=false
  if echo "$pull_output" | grep -qiE \
      "pull complete|downloaded newer image|: pulled|Status: Downloaded newer"; then
    update_detected=true
  fi

  # Secondary check: compare each running container's image ID against the
  # currently available local image. This catches the case where the same
  # image is shared across multiple projects — Docker reports "up to date"
  # on the second pull (the layers are already present), but the running
  # containers in this project are still using the old image.
  if [[ "$update_detected" == false ]]; then
    while IFS= read -r container_id; do
      [[ -z "$container_id" ]] && continue
      container_image_id=$(sudo docker inspect "$container_id" \
        --format '{{.Image}}' 2>/dev/null || true)
      image_name=$(sudo docker inspect "$container_id" \
        --format '{{.Config.Image}}' 2>/dev/null || true)
      [[ -z "$container_image_id" || -z "$image_name" ]] && continue
      current_image_id=$(sudo docker image inspect "$image_name" \
        --format '{{.Id}}' 2>/dev/null || true)
      if [[ -n "$current_image_id" && "$container_image_id" != "$current_image_id" ]]; then
        update_detected=true
        break
      fi
    done < <($COMPOSE -f "$compose_file" ps --status running --quiet 2>/dev/null)
  fi

  if [[ "$update_detected" == true ]]; then
    ok "${project_name}: new image(s) found — restarting project."

    # Bring the project down (removes containers, keeps volumes/networks)
    $COMPOSE -f "$compose_file" down || {
      err "${project_name}: 'compose down' failed."
      failed_projects+=("${project_name}")
      echo
      continue
    }

    # Bring it back up in detached mode
    $COMPOSE -f "$compose_file" up -d || {
      err "${project_name}: 'compose up' failed."
      failed_projects+=("${project_name}")
      echo
      continue
    }

    ok "${project_name}: restarted successfully."
    updated_projects+=("${project_name}")

  else
    log "${project_name}: all images already up to date — no restart needed."
    skipped_projects+=("${project_name} (already up to date)")
  fi

  echo
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo -e "${BOLD}====== Summary ======${RESET}"

if [[ ${#updated_projects[@]} -gt 0 ]]; then
  ok "Updated & restarted (${#updated_projects[@]}):"
  for p in "${updated_projects[@]}"; do echo "    • $p"; done
fi

if [[ ${#skipped_projects[@]} -gt 0 ]]; then
  warn "Skipped (${#skipped_projects[@]}):"
  for p in "${skipped_projects[@]}"; do echo "    • $p"; done
fi

if [[ ${#failed_projects[@]} -gt 0 ]]; then
  err "Failed (${#failed_projects[@]}):"
  for p in "${failed_projects[@]}"; do echo "    • $p"; done
  exit 1
fi

exit 0
