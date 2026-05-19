# docker-update

A Bash script that keeps Docker Compose projects up to date by pulling fresh images and restarting only the projects where something actually changed.

## What it does

- Scans every subdirectory of `/volume2/docker/` for a Compose file
- Skips projects with no running containers
- Pulls the latest images for each running project
- Restarts a project **only** if at least one image was updated — no unnecessary downtime
- Prints a colour-coded summary of what was updated, skipped, and failed

## Requirements

- Bash 4+
- Docker with the Compose plugin (`docker compose`) **or** standalone `docker-compose`
- `sudo` access for Docker commands

## Configuration

The scan root is hardcoded at the top of the script:

```bash
COMPOSE_ROOT="/volume2/docker"
```

Change this to match your setup before running.

## Usage

Make the script executable once:

```bash
chmod +x docker-update.sh
```

Run manually:

```bash
./docker-update.sh
```

### Cron example

Run every night at 03:00:

```cron
0 3 * * * /path/to/docker-update.sh >> /var/log/docker-update.log 2>&1
```

Colour output is suppressed automatically when running non-interactively.

## How it works

1. Detects whether to use `docker compose` (plugin) or `docker-compose` (standalone)
2. Loops over each subdirectory in `COMPOSE_ROOT`
3. Looks for a Compose file (`docker-compose.yml`, `docker-compose.yaml`, `compose.yml`, `compose.yaml`)
4. Counts running containers — skips the project if none are running
5. Runs `compose pull` and inspects the output for update markers (`Pull complete`, `Downloaded newer image`, `Pulled`, etc.)
6. If an update is found: runs `compose down` then `compose up -d`
7. Prints a summary and exits with code `1` if any project failed

## License

MIT
