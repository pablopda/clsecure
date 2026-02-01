#!/usr/bin/env bats
# test_config.bats
# 
# Tests for lib/config.sh

load test_helpers

setup() {
    setup_test
    source_module "vars.sh"
    init_clsecure_vars
    source_module "logging.sh"
    source_module "config.sh"
    
    # Create test config file
    mkdir -p "$HOME/.config/clsecure"
    cat > "$HOME/.config/clsecure/config" << EOF
mode = namespace
network = false
docker = true
install_dependencies = true
EOF
}

teardown() {
    teardown_test
    rm -f "$HOME/.config/clsecure/config"
}

@test "load_config function exists" {
    assert_function_exists load_config
}

@test "show_config_info function exists" {
    assert_function_exists show_config_info
}

@test "load_config reads config file" {
    load_config
    [ "$ISOLATION_MODE" = "namespace" ]
    [ "$ALLOW_NETWORK" = "false" ]
    [ "$ALLOW_DOCKER" = "true" ]
    [ "$INSTALL_DEPS" = "true" ]
}

@test "load_config uses defaults when config file missing" {
    rm -f "$HOME/.config/clsecure/config"
    rm -f "$HOME/.clsecurerc"
    
    init_clsecure_vars
    load_config
    
    # Should use defaults
    [ -n "$ISOLATION_MODE" ]
}

@test "show_config_info displays config" {
    load_config
    run show_config_info
    [ "$status" -eq 0 ]
    [[ "$output" == *"Configuration"* ]]
}

@test "load_config reads cleanup_hook_timeout" {
    cat >> "$HOME/.config/clsecure/config" << EOF
cleanup_hook_timeout = 60
EOF
    init_clsecure_vars
    load_config
    [ "$CLEANUP_HOOK_TIMEOUT" = "60" ]
}

@test "load_config rejects cleanup_hook_timeout below minimum" {
    cat > "$HOME/.config/clsecure/config" << EOF
cleanup_hook_timeout = 3
EOF
    init_clsecure_vars
    load_config
    # Should keep default (3 < 5 minimum)
    [ "$CLEANUP_HOOK_TIMEOUT" = "30" ]
}

@test "load_config rejects cleanup_hook_timeout above maximum" {
    cat > "$HOME/.config/clsecure/config" << EOF
cleanup_hook_timeout = 500
EOF
    init_clsecure_vars
    load_config
    # Should keep default (500 > 300 maximum)
    [ "$CLEANUP_HOOK_TIMEOUT" = "30" ]
}

@test "load_config reads skip_docker_autodetect" {
    cat >> "$HOME/.config/clsecure/config" << EOF
skip_docker_autodetect = true
EOF
    init_clsecure_vars
    load_config
    [ "$SKIP_DOCKER_AUTODETECT" = "true" ]
}

@test "load_config defaults cleanup variables when not in config" {
    # Config file exists but doesn't have cleanup keys
    init_clsecure_vars
    load_config
    [ "$CLEANUP_HOOK_TIMEOUT" = "30" ]
    [ "$SKIP_DOCKER_AUTODETECT" = "false" ]
}
