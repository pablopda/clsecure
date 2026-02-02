# Cleanup Hooks

When a clsecure session ends, resources like background processes, Docker containers, and temporary services may still be running under the worker user. Cleanup hooks let your project define how these resources should be torn down.

## How Cleanup Works

clsecure uses a two-tier cleanup system:

1. **Tier 1 (Application)** — Your project's cleanup hook runs first, or if no hook exists, clsecure auto-detects Docker Compose files as a fallback.
2. **Tier 2 (OS)** — All remaining processes owned by the worker user are killed with SIGTERM, then SIGKILL after 5 seconds.

Tier 1 runs before Tier 2 so that hooks can interact with services that are still alive (e.g., `docker compose down` needs the Docker daemon socket).

### When Cleanup Runs

| User Choice | Cleanup Level | Cleanup Runs? |
|---|---|---|
| 1) Import changes | `stop` | Yes |
| 2) Discard changes | `stop` or `purge` (asks if Docker volumes should be removed) | Yes |
| 3) Keep for later | — | No |
| No changes + remove user | `stop` | Yes |
| `clsecure --cleanup` | `stop` | Yes |
| `clsecure --cleanup-all` | `purge` | Yes |

## Creating a Cleanup Hook

Place an executable script at `.clsecure/on-cleanup` in your project root:

```
your-project/
  .clsecure/
    on-cleanup      # Must be executable
  docker-compose.yml
  src/
  ...
```

Make it executable:

```bash
mkdir -p .clsecure
chmod +x .clsecure/on-cleanup
```

### Minimal Example

```bash
#!/bin/bash
docker compose down
```

### Full Example

```bash
#!/bin/bash
# .clsecure/on-cleanup
#
# Cleanup hook for myapp development environment

set -euo pipefail

# Use session name to namespace Docker resources
export COMPOSE_PROJECT_NAME="myapp-${CLSECURE_SESSION:-default}"

case "$CLSECURE_CLEANUP_LEVEL" in
    stop)
        # Normal cleanup: stop containers, keep volumes
        docker compose down
        ;;
    purge)
        # Full cleanup: remove everything including data volumes
        docker compose down -v --remove-orphans
        docker image prune -f --filter "label=project=myapp"
        ;;
esac

# Stop any background dev servers
pkill -f "node.*dev-server" 2>/dev/null || true
```

## Environment Variables

Your hook receives the following environment variables:

| Variable | Description | Example |
|---|---|---|
| `CLSECURE_SESSION` | Session name (empty if no `--session` flag) | `auth` |
| `CLSECURE_CLEANUP_LEVEL` | `stop` (keep data) or `purge` (destroy data) | `stop` |
| `CLSECURE_PROJECT_DIR` | Project path inside worker home | `/home/claude-worker-myapp-a1b2c3/project` |
| `CLSECURE_WORKER_USER` | Worker username | `claude-worker-myapp-a1b2c3` |
| `CLSECURE_WORKER_HOME` | Worker home directory | `/home/claude-worker-myapp-a1b2c3` |

## Cleanup Levels

- **`stop`** — Normal session end. Stop running services but preserve data (database volumes, caches, build artifacts). Used when importing changes or removing an idle worker.
- **`purge`** — Full teardown. Destroy everything including data volumes and ephemeral storage. Used with `--cleanup-all` or when the user explicitly chooses to remove Docker volumes on discard.

Your hook should handle both levels. If you only care about one, a simple `docker compose down` for both is fine.

## Docker Auto-Detection

When no cleanup hook exists and Docker access is enabled (`--allow-docker`), clsecure automatically looks for a Compose file in the project root:

- `docker-compose.yml`
- `docker-compose.yaml`
- `compose.yml`
- `compose.yaml`

If found, it runs:
- `docker compose down` for `stop` level
- `docker compose down -v --remove-orphans` for `purge` level

This fallback covers the common case without requiring a hook. To disable it, set `skip_docker_autodetect = true` in your clsecure config file.

## Security Constraints

- The hook runs **as the worker user**, not as root.
- The hook has a **timeout** (default: 30 seconds). If it exceeds this, it is terminated and cleanup continues. Configure with `cleanup_hook_timeout` in your clsecure config.
- The hook file must be a **regular file** (or symlink that resolves within the project). Symlinks pointing outside the project directory are rejected.
- The hook must be **executable** (`chmod +x`).
- Hook failure is **non-fatal** — Tier 2 process termination always runs regardless of hook exit code.

## Configuration

These settings can go in your project config (`.clsecure/config`) or user config (`~/.config/clsecure/config` or `~/.clsecurerc`):

```ini
# Timeout for cleanup hooks in seconds (5-300, default: 30)
cleanup_hook_timeout = 30

# Skip Docker auto-detection during cleanup (default: false)
skip_docker_autodetect = false
```

Both `cleanup_hook_timeout` and `skip_docker_autodetect` are project-safe settings, so they can be committed to version control in `.clsecure/config`.

## Recipes

### Docker Compose with Multiple Profiles

```bash
#!/bin/bash
# .clsecure/on-cleanup
docker compose --profile dev --profile tools down
[ "$CLSECURE_CLEANUP_LEVEL" = "purge" ] && docker volume prune -f
```

### Session-Scoped Containers

```bash
#!/bin/bash
# .clsecure/on-cleanup
# Each session gets its own compose project
export COMPOSE_PROJECT_NAME="myapp-${CLSECURE_SESSION:-default}"

if [ "$CLSECURE_CLEANUP_LEVEL" = "purge" ]; then
    docker compose down -v --remove-orphans
else
    docker compose down
fi
```

### Background Processes Only (No Docker)

```bash
#!/bin/bash
# .clsecure/on-cleanup
# Kill specific processes before the blanket pkill in Tier 2
redis-cli shutdown nosave 2>/dev/null || true
pg_ctl -D "$CLSECURE_PROJECT_DIR/.pgdata" stop -m fast 2>/dev/null || true
```

### Conditional Cleanup by Session Name

```bash
#!/bin/bash
# .clsecure/on-cleanup
case "$CLSECURE_SESSION" in
    e2e|integration)
        docker compose -f docker-compose.test.yml down
        ;;
    *)
        docker compose down
        ;;
esac
```
