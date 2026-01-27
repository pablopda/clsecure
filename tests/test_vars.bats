#!/usr/bin/env bats
# test_vars.bats
# 
# Tests for lib/vars.sh

load test_helpers

setup() {
    setup_test
    source_module "vars.sh"
}

teardown() {
    teardown_test
}

@test "init_clsecure_vars initializes all core variables" {
    init_clsecure_vars
    
    [ -n "$WORKER_PREFIX" ]
    [ -n "$CURRENT_DIR" ]
    [ -n "$PROJECT_NAME" ]
    [ -n "$PROJECT_NAME_SANITIZED" ]
    [ -n "$PROJECT_HASH" ]
}

@test "init_clsecure_vars sets worker variables" {
    init_clsecure_vars
    
    [ -n "$WORKER_USER" ]
    [ -n "$WORKER_HOME" ]
    [ -n "$WORKER_PROJECT" ]
    [[ "$WORKER_USER" == claude-worker-* ]]
}

@test "init_clsecure_vars sets lock variables" {
    init_clsecure_vars
    
    [ -n "$LOCK_DIR" ]
    [ -n "$LOCK_FILE" ]
}

@test "init_clsecure_vars sets config variables" {
    init_clsecure_vars
    
    [ -n "$ISOLATION_MODE" ]
    [ -n "$ALLOW_NETWORK" ]
    [ -n "$ALLOW_DOCKER" ]
    [ -n "$INSTALL_DEPS" ]
}

@test "init_clsecure_vars sets color constants" {
    init_clsecure_vars
    
    [ -n "$RED" ]
    [ -n "$GREEN" ]
    [ -n "$YELLOW" ]
    [ -n "$BLUE" ]
    [ -n "$CYAN" ]
    [ -n "$NC" ]
}

@test "init_clsecure_vars exports required variables" {
    init_clsecure_vars
    
    # Check that variables are exported (available to child processes)
    env | grep -q "^WORKER_USER=" || false
    env | grep -q "^WORKER_HOME=" || false
    env | grep -q "^ISOLATION_MODE=" || false
}
