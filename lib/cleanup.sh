#!/bin/bash
# lib/cleanup.sh
#
# Session cleanup for clsecure (application hooks + OS-level process termination)
#
# Dependencies: lib/logging.sh, lib/worker.sh, lib/vars.sh
# Exports: cleanup_session, validate_cleanup_hook, run_cleanup_hook, auto_detect_docker_cleanup, kill_worker_processes
#
# Usage:
#   source lib/cleanup.sh
#   cleanup_session "stop"    # Normal cleanup (keep data volumes)
#   cleanup_session "purge"   # Full cleanup (destroy data volumes)

# Top-level cleanup orchestrator
# Args: cleanup_level ("stop" or "purge")
cleanup_session() {
    local cleanup_level="${1:-stop}"

    # Guard against unset worker variables
    if [ -z "${WORKER_USER:-}" ] || [ -z "${WORKER_PROJECT:-}" ]; then
        log_warn "Cannot run cleanup: worker variables not set"
        return 0
    fi

    log_step "Cleaning up session resources..."

    # Tier 1: Application hook (if exists and valid)
    if validate_cleanup_hook; then
        run_cleanup_hook "$cleanup_level"
    elif [ "$ALLOW_DOCKER" = true ] && [ "$SKIP_DOCKER_AUTODETECT" = false ]; then
        auto_detect_docker_cleanup "$cleanup_level"
    fi

    # Tier 2: OS-level process kill (unconditional)
    kill_worker_processes
}

# Validate the project cleanup hook
# Returns 0 if hook is valid and should be run, 1 otherwise
validate_cleanup_hook() {
    local hook_path="$WORKER_PROJECT/.clsecure/on-cleanup"

    # Must exist as a regular file
    if ! sudo test -f "$hook_path"; then
        return 1
    fi

    # Must be executable
    if ! sudo test -x "$hook_path"; then
        log_warn "Cleanup hook exists but is not executable: $hook_path"
        return 1
    fi

    # Must not symlink outside project directory
    local resolved_path
    resolved_path=$(sudo readlink -f "$hook_path" 2>/dev/null || echo "")
    if [ -z "$resolved_path" ]; then
        log_warn "Cannot resolve cleanup hook path"
        return 1
    fi

    # Ensure resolved path is within the worker project
    case "$resolved_path" in
        "$WORKER_PROJECT"/*)
            return 0
            ;;
        *)
            log_warn "Cleanup hook symlinks outside project directory: $resolved_path"
            return 1
            ;;
    esac
}

# Run the project cleanup hook as the worker user
# Args: cleanup_level ("stop" or "purge")
run_cleanup_hook() {
    local cleanup_level="${1:-stop}"
    local hook_path="$WORKER_PROJECT/.clsecure/on-cleanup"

    log_info "Running project cleanup hook..."

    local exit_code=0
    sudo -u "$WORKER_USER" \
        env \
            CLSECURE_SESSION="${SESSION_NAME:-}" \
            CLSECURE_CLEANUP_LEVEL="$cleanup_level" \
            CLSECURE_PROJECT_DIR="$WORKER_PROJECT" \
            CLSECURE_WORKER_USER="$WORKER_USER" \
            CLSECURE_WORKER_HOME="$WORKER_HOME" \
        timeout "$CLEANUP_HOOK_TIMEOUT" \
        "$hook_path" || exit_code=$?

    if [ "$exit_code" -eq 124 ]; then
        log_warn "Cleanup hook timed out after ${CLEANUP_HOOK_TIMEOUT}s"
    elif [ "$exit_code" -ne 0 ]; then
        log_warn "Cleanup hook exited with code $exit_code"
    fi

    # Always continue to Tier 2 regardless of hook result
    return 0
}

# Auto-detect and clean up docker compose resources
# Fallback when no cleanup hook exists but docker is enabled
# Args: cleanup_level ("stop" or "purge")
auto_detect_docker_cleanup() {
    local cleanup_level="${1:-stop}"

    # Check if docker is available
    if ! command -v docker &>/dev/null; then
        return 0
    fi

    # Search for compose file in project directory
    local compose_file=""
    for candidate in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
        if sudo test -f "$WORKER_PROJECT/$candidate"; then
            compose_file="$candidate"
            break
        fi
    done

    if [ -z "$compose_file" ]; then
        return 0
    fi

    log_info "Auto-detected $compose_file, running docker compose down..."

    local docker_args="down"
    if [ "$cleanup_level" = "purge" ]; then
        docker_args="down -v --remove-orphans"
    fi

    sudo -u "$WORKER_USER" bash -c "cd '$WORKER_PROJECT' && docker compose $docker_args" || {
        log_warn "Docker compose cleanup failed (non-fatal)"
    }

    return 0
}

# Kill all processes owned by the worker user (Tier 2 brute force)
kill_worker_processes() {
    # Check if any processes exist
    if ! sudo pgrep -u "$WORKER_USER" &>/dev/null; then
        return 0
    fi

    log_info "Terminating processes for $WORKER_USER..."

    # SIGTERM first
    sudo pkill -TERM -u "$WORKER_USER" 2>/dev/null || true

    # Wait up to 5 seconds
    local wait_count=0
    while sudo pgrep -u "$WORKER_USER" &>/dev/null && [ "$wait_count" -lt 10 ]; do
        sleep 0.5
        wait_count=$((wait_count + 1))
    done

    # SIGKILL remaining
    if sudo pgrep -u "$WORKER_USER" &>/dev/null; then
        log_warn "Sending SIGKILL to remaining processes..."
        sudo pkill -KILL -u "$WORKER_USER" 2>/dev/null || true
        sleep 1
    fi
}
