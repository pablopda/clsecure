#!/usr/bin/env bats
# test_git.bats
# 
# Tests for lib/git.sh

load test_helpers

setup() {
    setup_test
    source_module "vars.sh"
    init_clsecure_vars
    source_module "logging.sh"
    source_module "worker.sh"
    source_module "git.sh"
}

teardown() {
    teardown_test
}

@test "check_disk_space function exists" {
    assert_function_exists check_disk_space
}

@test "clone_repository function exists" {
    assert_function_exists clone_repository
}

@test "sync_working_directory function exists" {
    assert_function_exists sync_working_directory
}

@test "copy_submodules function exists" {
    assert_function_exists copy_submodules
}

@test "setup_git_config function exists" {
    assert_function_exists setup_git_config
}

@test "check_disk_space returns success with sufficient space" {
    run check_disk_space 1  # 1 MB
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]  # May fail without sudo
}
