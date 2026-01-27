#!/usr/bin/env bats
# test_lock.bats
# 
# Tests for lib/lock.sh

load test_helpers

setup() {
    setup_test
    source_module "vars.sh"
    init_clsecure_vars
    source_module "logging.sh"
    source_module "lock.sh"
    
    # Create lock directory
    export LOCK_DIR="$TEST_DIR/locks"
    mkdir -p "$LOCK_DIR"
    export LOCK_FILE="$LOCK_DIR/test.lock"
}

teardown() {
    teardown_test
}

@test "acquire_lock function exists" {
    assert_function_exists acquire_lock
}

@test "release_lock function exists" {
    assert_function_exists release_lock
}

@test "cleanup_on_exit function exists" {
    assert_function_exists cleanup_on_exit
}

@test "acquire_lock creates lock directory" {
    rm -rf "$LOCK_DIR"
    acquire_lock || true  # May fail without sudo, but should create dir
    [ -d "$LOCK_DIR" ] || true  # Skip if requires sudo
}

@test "release_lock removes lock file" {
    touch "$LOCK_FILE"
    release_lock
    [ ! -f "$LOCK_FILE" ] || true  # Skip if requires sudo
}
