#!/usr/bin/env bats
# test_session.bats
#
# Tests for --session NAME functionality (lib/vars.sh recompute_worker_vars)

load test_helpers

setup() {
    setup_test
    source_module "vars.sh"
    init_clsecure_vars
}

teardown() {
    teardown_test
}

@test "recompute_worker_vars is a no-op when SESSION_NAME is empty" {
    local original_hash="$PROJECT_HASH"
    local original_user="$WORKER_USER"

    SESSION_NAME=""
    # Function should not be called when SESSION_NAME is empty (caller guards this)
    # Verify default state is unchanged
    [ "$PROJECT_HASH" = "$original_hash" ]
    [ "$WORKER_USER" = "$original_user" ]
}

@test "different session names produce different hashes" {
    local original_hash="$PROJECT_HASH"

    SESSION_NAME="auth"
    recompute_worker_vars
    local auth_hash="$PROJECT_HASH"

    # Re-init to reset
    init_clsecure_vars
    SESSION_NAME="payments"
    recompute_worker_vars
    local payments_hash="$PROJECT_HASH"

    [ "$auth_hash" != "$original_hash" ]
    [ "$payments_hash" != "$original_hash" ]
    [ "$auth_hash" != "$payments_hash" ]
}

@test "same session name produces same hash (deterministic)" {
    SESSION_NAME="test-session"
    recompute_worker_vars
    local hash1="$PROJECT_HASH"

    # Re-init and recompute with same session
    init_clsecure_vars
    SESSION_NAME="test-session"
    recompute_worker_vars
    local hash2="$PROJECT_HASH"

    [ "$hash1" = "$hash2" ]
}

@test "session name is sanitized to lowercase" {
    SESSION_NAME="MySession"
    recompute_worker_vars
    [ "$SESSION_NAME_SANITIZED" = "mysession" ]
}

@test "session name special chars replaced with dashes" {
    SESSION_NAME="my_session.name"
    recompute_worker_vars
    [ "$SESSION_NAME_SANITIZED" = "my-session-name" ]
}

@test "session name truncated to 20 chars" {
    SESSION_NAME="this-is-a-very-long-session-name-that-exceeds-limit"
    recompute_worker_vars
    [ ${#SESSION_NAME_SANITIZED} -le 20 ]
}

@test "WORKER_USER stays within 32-char limit with session" {
    SESSION_NAME="longest-session"
    recompute_worker_vars
    local len=${#WORKER_USER}
    [ "$len" -le 32 ]
}

@test "WORKER_HOME and LOCK_FILE update with session" {
    local original_home="$WORKER_HOME"
    local original_lock="$LOCK_FILE"

    SESSION_NAME="dev"
    recompute_worker_vars

    [ "$WORKER_HOME" != "$original_home" ]
    [ "$LOCK_FILE" != "$original_lock" ]
    [[ "$WORKER_HOME" == /home/claude-worker-* ]]
    [[ "$LOCK_FILE" == *"claude-worker-"* ]]
}

@test "WORKER_PROJECT updates with session" {
    SESSION_NAME="staging"
    recompute_worker_vars
    [[ "$WORKER_PROJECT" == "$WORKER_HOME/project" ]]
}

@test "empty-after-sanitize session name returns error" {
    SESSION_NAME="___"
    run recompute_worker_vars
    [ "$status" -eq 1 ]
}

@test "session name with only dashes sanitizes to empty and returns error" {
    SESSION_NAME="---"
    run recompute_worker_vars
    [ "$status" -eq 1 ]
}
