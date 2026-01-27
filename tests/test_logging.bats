#!/usr/bin/env bats
# test_logging.bats
# 
# Tests for lib/logging.sh

load test_helpers

setup() {
    setup_test
    source_module "vars.sh"
    init_clsecure_vars
    source_module "logging.sh"
}

teardown() {
    teardown_test
}

@test "log_info function exists" {
    assert_function_exists log_info
}

@test "log_warn function exists" {
    assert_function_exists log_warn
}

@test "log_error function exists" {
    assert_function_exists log_error
}

@test "log_step function exists" {
    assert_function_exists log_step
}

@test "log_security function exists" {
    assert_function_exists log_security
}

@test "log_info outputs message" {
    run log_info "Test message"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Test message"* ]]
}

@test "log_warn outputs message" {
    run log_warn "Warning message"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Warning message"* ]]
}

@test "log_error outputs message" {
    run log_error "Error message"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Error message"* ]]
}
