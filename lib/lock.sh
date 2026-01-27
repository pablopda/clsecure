#!/bin/bash
# lib/lock.sh
# 
# Lock management for clsecure
# 
# Dependencies: lib/logging.sh, lib/vars.sh
# Exports: acquire_lock, release_lock, cleanup_on_exit
# 
# Usage:
#   source lib/lock.sh
#   acquire_lock || exit 1
#   # ... do work ...
#   release_lock

# Acquire lock atomically to prevent concurrent sessions
acquire_lock() {
    mkdir -p "$LOCK_DIR" 2>/dev/null || sudo mkdir -p "$LOCK_DIR"
    sudo chmod 1777 "$LOCK_DIR" 2>/dev/null || true

    # Use flock for atomic lock acquisition to prevent race conditions
    # Try to acquire lock with timeout of 0 (non-blocking)
    if command -v flock &>/dev/null; then
        # Use a temporary file descriptor to capture subshell exit code
        # The subshell's exit code determines if we got the lock
        if ! (
            flock -n 9 || exit 1
            # Check if existing lock file has a valid process
            if [ -f "$LOCK_FILE" ]; then
                local pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
                if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                    exit 1
                fi
                rm -f "$LOCK_FILE" 2>/dev/null || sudo rm -f "$LOCK_FILE"
            fi
            # Write our PID to lock file
            echo $$ > "$LOCK_FILE" 2>/dev/null || echo $$ | sudo tee "$LOCK_FILE" > /dev/null
            exit 0
        ) 9>"$LOCK_FILE"; then
            # Subshell exited with non-zero (lock failed)
            return 1
        fi
        # Subshell exited with zero (lock acquired)
        return 0
    else
        # Fallback to original method if flock not available
        if [ -f "$LOCK_FILE" ]; then
            local pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                return 1
            fi
            rm -f "$LOCK_FILE" 2>/dev/null || sudo rm -f "$LOCK_FILE"
        fi
        echo $$ > "$LOCK_FILE" 2>/dev/null || echo $$ | sudo tee "$LOCK_FILE" > /dev/null
        return 0
    fi
}

# Release lock
release_lock() {
    rm -f "$LOCK_FILE" 2>/dev/null || sudo rm -f "$LOCK_FILE" 2>/dev/null || true
}

# Cleanup handler for trap (called on exit)
cleanup_on_exit() {
    release_lock
}
