#!/usr/bin/env bash
# =============================================================================
# Regression tests for docker-update.sh, run against the fake docker binary in
# tests/stub/ — no Docker daemon required. Exercises every code path: skip
# reasons, update detection, restart, sidecar fallback, failures, dry-run,
# locking, and argument handling.
#
# Usage: tests/run-tests.sh
# =============================================================================
set -euo pipefail

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$(dirname "$TESTS_DIR")/docker-update.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

export PATH="$TESTS_DIR/stub:$PATH"
export STUB_STATE="$WORK/state"
export SETTLE_SECONDS=0
export TMPDIR="$WORK"
ROOT="$WORK/root"

PASS=0; FAIL=0
pass() { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

assert_eq()       { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }
assert_contains() { if grep -qF -- "$2" <<<"$3"; then pass "$1"; else fail "$1 (output missing '$2')"; fi; }
assert_missing()  { if ! grep -qF -- "$2" <<<"$3"; then pass "$1"; else fail "$1 (output unexpectedly contains '$2')"; fi; }
assert_file()     { if [[ -e "$2" ]]; then pass "$1"; else fail "$1 (missing file $2)"; fi; }
assert_no_file()  { if [[ ! -e "$2" ]]; then pass "$1"; else fail "$1 (unexpected file $2)"; fi; }

# Fresh state + compose root for each test
reset_env() {
  rm -rf "$ROOT" "$STUB_STATE" "$WORK/docker-update.lock"
  mkdir -p "$ROOT" "$STUB_STATE/container_image" "$STUB_STATE/container_name" "$STUB_STATE/image_id"
}

# new_project NAME CID IMAGE_NAME CONTAINER_IMAGE_ID CURRENT_IMAGE_ID SERVICES...
# Creates a project dir with one running container and the given service list.
new_project() {
  local name="$1" cid="$2" image="$3" have="$4" current="$5"; shift 5
  mkdir -p "$ROOT/$name"
  touch "$ROOT/$name/compose.yml"
  echo "$cid" > "$ROOT/$name/.stub_ids"
  printf '%s\n' "$@" > "$ROOT/$name/.stub_services"
  echo "$have"    > "$STUB_STATE/container_image/$cid"
  echo "$image"   > "$STUB_STATE/container_name/$cid"
  echo "$current" > "$STUB_STATE/image_id/${image//\//_}"
}

# run_script [ARGS...] — runs docker-update.sh, sets $output and $rc
run_script() {
  rc=0
  output=$(bash "$SCRIPT" --root "$ROOT" "$@" 2>&1) || rc=$?
}

# ---------------------------------------------------------------------------
echo "test: skip paths (no compose file, marker, not running)"
reset_env
mkdir -p "$ROOT/nocompose"
mkdir -p "$ROOT/pinned" && touch "$ROOT/pinned/compose.yml" "$ROOT/pinned/.no-update"
mkdir -p "$ROOT/stopped" && touch "$ROOT/stopped/docker-compose.yml" "$ROOT/stopped/.stub_ids"
run_script
assert_eq        "exits 0"                 0 "$rc"
assert_contains  "no compose file skipped" "nocompose (no compose file)" "$output"
assert_contains  "marker skipped"          "pinned (marked .no-update)" "$output"
assert_contains  "not running skipped"     "stopped (not running)" "$output"
assert_missing   "nothing updated"         "Updated" "$output"

# ---------------------------------------------------------------------------
echo "test: up-to-date project is not restarted"
reset_env
new_project current c1 nginx:latest sha256:aaa sha256:aaa web
run_script
assert_eq       "exits 0"            0 "$rc"
assert_contains "reported up to date" "current (already up to date)" "$output"
assert_no_file  "no 'up' performed"  "$ROOT/current/.stub_up_count"
assert_no_file  "no prune"           "$STUB_STATE/pruned"

# ---------------------------------------------------------------------------
echo "test: updated image triggers up -d (no down) and prune"
reset_env
new_project app c2 ghcr.io/foo/app:latest sha256:old sha256:new app tailscale
printf 'app\ntailscale\n' > "$ROOT/app/.stub_services_after_1"
run_script
assert_eq       "exits 0"              0 "$rc"
assert_contains "reported updated"     "app: updated and restarted successfully" "$output"
assert_eq       "exactly one 'up'"     1 "$(cat "$ROOT/app/.stub_up_count")"
assert_no_file  "no 'down' performed"  "$ROOT/app/.stub_down_done"
assert_file     "dangling images pruned" "$STUB_STATE/pruned"

# ---------------------------------------------------------------------------
echo "test: missing sidecar after up -d triggers down/up fallback"
reset_env
new_project side c3 foo/bar:1 sha256:old sha256:new app sidecar
printf 'app\n'          > "$ROOT/side/.stub_services_after_1"   # sidecar gone
printf 'app\nsidecar\n' > "$ROOT/side/.stub_services_after_2"   # recovered
run_script
assert_eq       "exits 0"             0 "$rc"
assert_contains "fallback triggered"  "trying full down/up" "$output"
assert_file     "'down' performed"    "$ROOT/side/.stub_down_done"
assert_eq       "two 'up' calls"      2 "$(cat "$ROOT/side/.stub_up_count")"
assert_contains "reported updated"    "side: updated and restarted successfully" "$output"

# ---------------------------------------------------------------------------
echo "test: fallback that still fails marks project failed"
reset_env
new_project broke c4 foo/bar:1 sha256:old sha256:new app sidecar
printf 'app\n' > "$ROOT/broke/.stub_services_after_1"
printf 'app\n' > "$ROOT/broke/.stub_services_after_2"
run_script
assert_eq       "exits 1"          1 "$rc"
assert_contains "failure reported" "still not running after full restart: sidecar" "$output"
assert_contains "in failed summary" "Failed (1):" "$output"

# ---------------------------------------------------------------------------
echo "test: pull failure marks project failed, others continue"
reset_env
new_project pullfail c5 nginx:latest sha256:aaa sha256:aaa web
touch "$ROOT/pullfail/.stub_pull_fail"
new_project healthy c6 redis:7 sha256:bbb sha256:bbb cache
run_script
assert_eq       "exits 1"               1 "$rc"
assert_contains "pull error logged"     "manifest unknown" "$output"
assert_contains "pullfail in failed"    "• pullfail" "$output"
assert_contains "healthy still handled" "healthy (already up to date)" "$output"

# ---------------------------------------------------------------------------
echo "test: 'compose ps' failure is a failure, not 'not running'"
reset_env
new_project psfail c7 nginx:latest sha256:aaa sha256:aaa web
touch "$ROOT/psfail/.stub_ps_fail"
run_script
assert_eq       "exits 1"              1 "$rc"
assert_contains "ps failure reported"  "'compose ps' failed" "$output"
assert_missing  "not counted as skipped" "psfail (not running)" "$output"

# ---------------------------------------------------------------------------
echo "test: stderr warnings from 'compose ps' are not mistaken for container IDs"
reset_env
# Stopped project: 'ps --quiet' prints nothing on stdout but a compose-style
# warning on stderr. That warning must not be treated as a running container.
mkdir -p "$ROOT/stopped-warn" && touch "$ROOT/stopped-warn/compose.yml" \
  "$ROOT/stopped-warn/.stub_ids" "$ROOT/stopped-warn/.stub_ps_warn"
# Running project with the same warning: the real container must still be
# detected exactly once, not miscounted because of the stderr noise.
new_project warned c9 nginx:latest sha256:aaa sha256:aaa web
touch "$ROOT/warned/.stub_ps_warn"
run_script
assert_eq       "exits 0"                       0 "$rc"
assert_contains "stopped project still skipped" "stopped-warn (not running)" "$output"
assert_contains "warning not counted as running" "warned: 1 running container(s) detected." "$output"
assert_contains "running project still detected" "warned (already up to date)" "$output"

# ---------------------------------------------------------------------------
echo "test: dry-run detects but changes nothing"
reset_env
new_project app c8 ghcr.io/foo/app:latest sha256:old sha256:new app
run_script --dry-run
assert_eq       "exits 0"            0 "$rc"
assert_contains "would restart"      "would restart (dry-run)" "$output"
assert_no_file  "no 'up' performed"  "$ROOT/app/.stub_up_count"
assert_no_file  "no prune"           "$STUB_STATE/pruned"

# ---------------------------------------------------------------------------
echo "test: concurrent run is refused via lockfile"
reset_env
rc=0
output=$( { flock 9; bash "$SCRIPT" --root "$ROOT" 2>&1; } 9>"$WORK/docker-update.lock" ) || rc=$?
assert_eq       "exits 1"        1 "$rc"
assert_contains "lock reported"  "already in progress" "$output"

# ---------------------------------------------------------------------------
echo "test: symlinked lock file is refused, not followed"
reset_env
canary="$WORK/canary"
printf 'untouched\n' > "$canary"
ln -s "$canary" "$WORK/docker-update.lock"
rc=0; output=$(bash "$SCRIPT" --root "$ROOT" 2>&1) || rc=$?
assert_eq       "exits 1"               1 "$rc"
assert_contains "symlink lock refused"  "it is a symlink" "$output"
assert_eq       "canary file untouched" "untouched" "$(cat "$canary")"

# ---------------------------------------------------------------------------
echo "test: argument handling"
reset_env
rc=0; bash "$SCRIPT" --root "$WORK/does-not-exist" >/dev/null 2>&1 || rc=$?
assert_eq "missing root exits 1" 1 "$rc"
rc=0; bash "$SCRIPT" --bogus >/dev/null 2>&1 || rc=$?
assert_eq "unknown option exits 2" 2 "$rc"
rc=0; bash "$SCRIPT" --root >/dev/null 2>&1 || rc=$?
assert_eq "--root without value exits 2" 2 "$rc"
rc=0; bash "$SCRIPT" --help >/dev/null 2>&1 || rc=$?
assert_eq "--help exits 0" 0 "$rc"

# ---------------------------------------------------------------------------
echo
echo "passed: $PASS, failed: $FAIL"
[[ $FAIL -eq 0 ]]
