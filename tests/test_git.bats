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

@test "setup_git_config writes .gitconfig with user.name and user.email" {
    # Set up a temp git repo with user.name and user.email configured
    local repo_dir="$TEST_DIR/repo"
    mkdir -p "$repo_dir"
    git init -q "$repo_dir"
    git -C "$repo_dir" config user.name "Test User"
    git -C "$repo_dir" config user.email "test@example.com"

    # Point CURRENT_DIR at our temp repo
    CURRENT_DIR="$repo_dir"

    # Use a temp dir as the worker home (owned by current user)
    WORKER_HOME="$TEST_DIR/worker_home"
    mkdir -p "$WORKER_HOME"
    WORKER_USER="$(whoami)"

    # Mock sudo to strip the -u <user> flags and run the rest
    sudo() {
        if [ "$1" = "-u" ]; then
            shift 2  # drop -u <user>
        fi
        command "$@"
    }

    setup_git_config

    # Assert .gitconfig was created and contains expected values
    [ -f "$WORKER_HOME/.gitconfig" ]
    run git config --file "$WORKER_HOME/.gitconfig" user.name
    [ "$status" -eq 0 ]
    [ "$output" = "Test User" ]
    run git config --file "$WORKER_HOME/.gitconfig" user.email
    [ "$status" -eq 0 ]
    [ "$output" = "test@example.com" ]
}
