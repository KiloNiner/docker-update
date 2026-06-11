# docker-update

A Bash script that keeps Docker Compose projects up to date by pulling fresh images and restarting only the projects where something actually changed.

## What it does

- Scans every subdirectory of the compose root (default `/volume2/docker/`) for a Compose file
- Skips projects with no running containers, and projects containing a `.no-update` marker file
- Pulls the latest images for each running project
- Restarts a project **only** if at least one image was updated — and uses `compose up -d`, so only the changed containers (and their dependents) are recreated, not the whole project
- Verifies that every service that was running before is running again; if not, falls back to a full `down` + `up -d` for that project
- Prunes dangling images at the end when something was updated
- Uses a lockfile so a manual run can never collide with the cron run
- Prints a colour-coded summary of what was updated, skipped, and failed

## Requirements

- Bash 4+
- Docker with the Compose v2 plugin (`docker compose`) **or** a standalone Compose v2 `docker-compose` binary
- Either direct Docker access (root / `docker` group) or passwordless `sudo` — the script auto-detects which to use and never blocks on a password prompt

## Usage

```bash
chmod +x docker-update.sh   # once

./docker-update.sh                 # normal run
./docker-update.sh --dry-run       # pull and report, but restart nothing
./docker-update.sh --root /srv/dk  # scan a different compose root
./docker-update.sh --help
```

The compose root can also be set with the `COMPOSE_ROOT` environment variable; `--root` takes precedence.

### Pinning a project

Create an empty marker file in any project directory you never want touched:

```bash
touch /volume2/docker/myproject/.no-update
```

### Cron example

Run every night at 03:00:

```cron
0 3 * * * /path/to/docker-update.sh >> /var/log/docker-update.log 2>&1
```

When output is not a terminal, colours are suppressed and each log line is prefixed with a timestamp.

## How it works

1. Takes a lock (`flock`) so concurrent runs exit immediately
2. Detects how to reach Docker (`docker`, or `sudo -n docker`) and whether to use the `docker compose` plugin or standalone `docker-compose`
3. Loops over each subdirectory in the compose root, skipping directories with a `.no-update` marker or no Compose file (`docker-compose.yml`, `docker-compose.yaml`, `compose.yml`, `compose.yaml`)
4. Runs Compose from *inside* each project directory, so `.env` and `docker-compose.override.yml` are honoured exactly as when running Compose by hand
5. Skips the project if no containers are running
6. Runs `compose pull`, then compares each running container's image ID against the now-current local image ID for its tag — an exact check that also catches images shared between projects, where the second project's pull is a no-op but its containers still run the old image
7. If an update is found: runs `compose up -d --remove-orphans`, which recreates only the changed containers and their dependents (including `network_mode: service:<name>` sidecars)
8. Verifies all previously-running services are running again; if any are missing, retries with a full `compose down` + `compose up -d` before marking the project failed
9. Prunes dangling images (`docker image prune -f`) when at least one project was updated (skipped in `--dry-run`)
10. Prints a summary and exits with code `1` if any project failed

### Notes

- `--dry-run` still pulls images (that is inherent to detecting updates); it only skips the restart and the prune.
- The lockfile lives at `${TMPDIR:-/tmp}/docker-update.lock`.

## Testing

The repository ships a regression test suite that runs against a fake `docker` binary (`tests/stub/docker`) — no Docker daemon needed:

```bash
tests/run-tests.sh
```

It covers every code path: skip reasons, update detection, restart without `down`, the sidecar fallback, pull/`ps` failures, dry-run, the lockfile, and argument handling. Note the stub mirrors the exact docker/compose commands the script uses — if you change which commands the script calls, update the stub to match. It validates the script's logic, not real Docker behaviour; `--dry-run` against a real host remains the integration check.

## License

MIT
