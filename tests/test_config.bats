#!/usr/bin/env bats
# test_config.bats
#
# Tests for lib/config.sh

load test_helpers

setup() {
    setup_test
    source_module "vars.sh"
    init_clsecure_vars
    # Override CURRENT_DIR to our test dir so PROJECT_CONFIG_FILE resolves there
    CURRENT_DIR="$TEST_DIR"
    PROJECT_CONFIG_FILE="$CURRENT_DIR/.clsecure/config"
    export CURRENT_DIR PROJECT_CONFIG_FILE
    source_module "logging.sh"
    source_module "config.sh"

    # Create test user config file
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
}

# Helper to reinit vars with test dir overrides
_reinit() {
    init_clsecure_vars
    CURRENT_DIR="$TEST_DIR"
    PROJECT_CONFIG_FILE="$CURRENT_DIR/.clsecure/config"
    export CURRENT_DIR PROJECT_CONFIG_FILE
}

# --- Function existence ---

@test "load_config function exists" {
    assert_function_exists load_config
}

@test "show_config_info function exists" {
    assert_function_exists show_config_info
}

@test "_parse_config_file function exists" {
    assert_function_exists _parse_config_file
}

@test "_trim function exists" {
    assert_function_exists _trim
}

@test "_is_valid_config_value function exists" {
    assert_function_exists _is_valid_config_value
}

# --- User config loading ---

@test "load_config reads user config file" {
    load_config
    [ "$ISOLATION_MODE" = "namespace" ]
    [ "$ALLOW_NETWORK" = "false" ]
    [ "$ALLOW_DOCKER" = "true" ]
    [ "$INSTALL_DEPS" = "true" ]
}

@test "load_config uses defaults when config file missing" {
    rm -f "$HOME/.config/clsecure/config"
    rm -f "$HOME/.clsecurerc"

    _reinit
    load_config

    # Should use defaults
    [ "$ISOLATION_MODE" = "namespace" ]
    [ "$ALLOW_NETWORK" = "true" ]
    [ "$ALLOW_DOCKER" = "false" ]
}

@test "load_config reads CONFIG_FILE_ALT fallback" {
    rm -f "$HOME/.config/clsecure/config"
    cat > "$HOME/.clsecurerc" << EOF
mode = container
docker = true
EOF

    _reinit
    load_config
    [ "$ISOLATION_MODE" = "container" ]
    [ "$ALLOW_DOCKER" = "true" ]

    rm -f "$HOME/.clsecurerc"
}

@test "show_config_info displays config" {
    load_config
    run show_config_info
    [ "$status" -eq 0 ]
    [[ "$output" == *"Configuration"* ]]
}

# --- Cleanup config keys (user config) ---

@test "load_config reads cleanup_hook_timeout" {
    cat >> "$HOME/.config/clsecure/config" << EOF
cleanup_hook_timeout = 60
EOF
    _reinit
    load_config
    [ "$CLEANUP_HOOK_TIMEOUT" = "60" ]
}

@test "load_config rejects cleanup_hook_timeout below minimum" {
    cat > "$HOME/.config/clsecure/config" << EOF
cleanup_hook_timeout = 3
EOF
    _reinit
    load_config
    [ "$CLEANUP_HOOK_TIMEOUT" = "30" ]
}

@test "load_config rejects cleanup_hook_timeout above maximum" {
    cat > "$HOME/.config/clsecure/config" << EOF
cleanup_hook_timeout = 500
EOF
    _reinit
    load_config
    [ "$CLEANUP_HOOK_TIMEOUT" = "30" ]
}

@test "load_config rejects non-numeric cleanup_hook_timeout" {
    cat > "$HOME/.config/clsecure/config" << EOF
cleanup_hook_timeout = abc
EOF
    _reinit
    load_config
    [ "$CLEANUP_HOOK_TIMEOUT" = "30" ]
}

@test "load_config reads skip_docker_autodetect" {
    cat >> "$HOME/.config/clsecure/config" << EOF
skip_docker_autodetect = true
EOF
    _reinit
    load_config
    [ "$SKIP_DOCKER_AUTODETECT" = "true" ]
}

@test "load_config defaults cleanup variables when not in config" {
    _reinit
    load_config
    [ "$CLEANUP_HOOK_TIMEOUT" = "30" ]
    [ "$SKIP_DOCKER_AUTODETECT" = "false" ]
}

# --- Project config: safe keys ---

@test "load_config reads project config for safe keys" {
    rm -f "$HOME/.config/clsecure/config"
    rm -f "$HOME/.clsecurerc"

    mkdir -p "$TEST_DIR/.clsecure"
    cat > "$TEST_DIR/.clsecure/config" << EOF
mode = container
EOF

    _reinit
    load_config
    [ "$ISOLATION_MODE" = "container" ]
}

@test "project config cleanup_hook_timeout is applied" {
    rm -f "$HOME/.config/clsecure/config"
    rm -f "$HOME/.clsecurerc"

    mkdir -p "$TEST_DIR/.clsecure"
    cat > "$TEST_DIR/.clsecure/config" << EOF
cleanup_hook_timeout = 120
EOF

    _reinit
    load_config
    [ "$CLEANUP_HOOK_TIMEOUT" = "120" ]
}

@test "project config skip_docker_autodetect is applied" {
    rm -f "$HOME/.config/clsecure/config"
    rm -f "$HOME/.clsecurerc"

    mkdir -p "$TEST_DIR/.clsecure"
    cat > "$TEST_DIR/.clsecure/config" << EOF
skip_docker_autodetect = true
EOF

    _reinit
    load_config
    [ "$SKIP_DOCKER_AUTODETECT" = "true" ]
}

# --- Project config: dangerous key rejection ---

@test "load_config ignores dangerous keys from project config" {
    rm -f "$HOME/.config/clsecure/config"
    rm -f "$HOME/.clsecurerc"

    mkdir -p "$TEST_DIR/.clsecure"
    cat > "$TEST_DIR/.clsecure/config" << EOF
docker = true
network = false
install_dependencies = true
setup_script = /tmp/evil.sh
EOF

    _reinit
    load_config
    [ "$ALLOW_DOCKER" = "false" ]
    [ "$ALLOW_NETWORK" = "true" ]
    [ "$INSTALL_DEPS" = "false" ]
    [ "$SETUP_SCRIPT" = "" ]
}

@test "load_config ignores dangerous key aliases from project config" {
    rm -f "$HOME/.config/clsecure/config"
    rm -f "$HOME/.clsecurerc"

    mkdir -p "$TEST_DIR/.clsecure"
    cat > "$TEST_DIR/.clsecure/config" << EOF
ALLOW_DOCKER = true
allow_network = false
INSTALL_DEPS = true
SETUP_SCRIPT = /tmp/evil.sh
EOF

    _reinit
    load_config
    [ "$ALLOW_DOCKER" = "false" ]
    [ "$ALLOW_NETWORK" = "true" ]
    [ "$INSTALL_DEPS" = "false" ]
    [ "$SETUP_SCRIPT" = "" ]
}

@test "load_config warns on dangerous docker key in project config" {
    rm -f "$HOME/.config/clsecure/config"
    rm -f "$HOME/.clsecurerc"

    mkdir -p "$TEST_DIR/.clsecure"
    cat > "$TEST_DIR/.clsecure/config" << EOF
docker = true
EOF

    _reinit
    run load_config
    [[ "$output" == *"ignored"* ]]
    [[ "$output" == *"docker"* ]]
}

@test "load_config warns on dangerous network key in project config" {
    rm -f "$HOME/.config/clsecure/config"
    rm -f "$HOME/.clsecurerc"

    mkdir -p "$TEST_DIR/.clsecure"
    cat > "$TEST_DIR/.clsecure/config" << EOF
network = false
EOF

    _reinit
    run load_config
    [[ "$output" == *"ignored"* ]]
    [[ "$output" == *"network"* ]]
}

@test "load_config warns on dangerous setup_script key in project config" {
    rm -f "$HOME/.config/clsecure/config"
    rm -f "$HOME/.clsecurerc"

    mkdir -p "$TEST_DIR/.clsecure"
    cat > "$TEST_DIR/.clsecure/config" << EOF
setup_script = /tmp/evil.sh
EOF

    _reinit
    run load_config
    [[ "$output" == *"ignored"* ]]
    [[ "$output" == *"setup_script"* ]]
}

@test "load_config warns on dangerous install_dependencies key in project config" {
    rm -f "$HOME/.config/clsecure/config"
    rm -f "$HOME/.clsecurerc"

    mkdir -p "$TEST_DIR/.clsecure"
    cat > "$TEST_DIR/.clsecure/config" << EOF
install_dependencies = true
EOF

    _reinit
    run load_config
    [[ "$output" == *"ignored"* ]]
    [[ "$output" == *"install_dependencies"* ]]
}

# --- Precedence: user config overrides project config ---

@test "user config overrides project config for mode" {
    mkdir -p "$TEST_DIR/.clsecure"
    cat > "$TEST_DIR/.clsecure/config" << EOF
mode = user
EOF

    # User config sets mode=namespace (already created in setup)
    _reinit
    load_config
    [ "$ISOLATION_MODE" = "namespace" ]
}

@test "user config overrides project config for cleanup_hook_timeout" {
    mkdir -p "$TEST_DIR/.clsecure"
    cat > "$TEST_DIR/.clsecure/config" << EOF
cleanup_hook_timeout = 120
EOF

    cat > "$HOME/.config/clsecure/config" << EOF
cleanup_hook_timeout = 60
EOF

    _reinit
    load_config
    [ "$CLEANUP_HOOK_TIMEOUT" = "60" ]
}

@test "user config overrides project config for skip_docker_autodetect" {
    mkdir -p "$TEST_DIR/.clsecure"
    cat > "$TEST_DIR/.clsecure/config" << EOF
skip_docker_autodetect = true
EOF

    cat > "$HOME/.config/clsecure/config" << EOF
skip_docker_autodetect = false
EOF

    _reinit
    load_config
    [ "$SKIP_DOCKER_AUTODETECT" = "false" ]
}

# --- Misplacement detection ---

@test "load_config detects misplaced .clsecure.conf" {
    rm -f "$HOME/.config/clsecure/config"
    rm -f "$HOME/.clsecurerc"

    touch "$TEST_DIR/.clsecure.conf"
    rm -rf "$TEST_DIR/.clsecure"

    _reinit
    run load_config
    [[ "$output" == *".clsecure.conf"* ]]
    [[ "$output" == *"ignored"* ]]
    [[ "$output" == *".clsecure/config"* ]]
}

@test "load_config does not warn when both .clsecure.conf and .clsecure/config exist" {
    rm -f "$HOME/.config/clsecure/config"
    rm -f "$HOME/.clsecurerc"

    touch "$TEST_DIR/.clsecure.conf"
    mkdir -p "$TEST_DIR/.clsecure"
    cat > "$TEST_DIR/.clsecure/config" << EOF
mode = user
EOF

    _reinit
    run load_config
    # Should NOT warn about misplaced config since valid one exists
    [[ "$output" != *".clsecure.conf"* ]]
}

# --- Edge cases ---

@test "load_config handles empty project config file" {
    rm -f "$HOME/.config/clsecure/config"
    rm -f "$HOME/.clsecurerc"

    mkdir -p "$TEST_DIR/.clsecure"
    touch "$TEST_DIR/.clsecure/config"

    _reinit
    load_config
    # Defaults should remain
    [ "$ISOLATION_MODE" = "namespace" ]
    [ "$ALLOW_NETWORK" = "true" ]
}

@test "load_config handles config with comments and blank lines" {
    rm -f "$HOME/.config/clsecure/config"
    rm -f "$HOME/.clsecurerc"

    mkdir -p "$TEST_DIR/.clsecure"
    cat > "$TEST_DIR/.clsecure/config" << EOF
# This is a comment
   # indented comment

mode = container

# another comment
cleanup_hook_timeout = 60
EOF

    _reinit
    load_config
    [ "$ISOLATION_MODE" = "container" ]
    [ "$CLEANUP_HOOK_TIMEOUT" = "60" ]
}

@test "load_config handles double-quoted values" {
    rm -f "$HOME/.config/clsecure/config"
    rm -f "$HOME/.clsecurerc"

    mkdir -p "$TEST_DIR/.clsecure"
    cat > "$TEST_DIR/.clsecure/config" << EOF
mode = "container"
EOF

    _reinit
    load_config
    [ "$ISOLATION_MODE" = "container" ]
}

@test "load_config handles single-quoted values" {
    rm -f "$HOME/.config/clsecure/config"
    rm -f "$HOME/.clsecurerc"

    mkdir -p "$TEST_DIR/.clsecure"
    cat > "$TEST_DIR/.clsecure/config" << EOF
mode = 'container'
EOF

    _reinit
    load_config
    [ "$ISOLATION_MODE" = "container" ]
}

@test "load_config rejects invalid mode value" {
    rm -f "$HOME/.config/clsecure/config"
    rm -f "$HOME/.clsecurerc"

    mkdir -p "$TEST_DIR/.clsecure"
    cat > "$TEST_DIR/.clsecure/config" << EOF
mode = invalid
EOF

    _reinit
    load_config
    [ "$ISOLATION_MODE" = "namespace" ]
}

@test "load_config accepts alternative boolean forms" {
    cat > "$HOME/.config/clsecure/config" << EOF
network = yes
docker = 1
skip_docker_autodetect = no
EOF

    _reinit
    load_config
    [ "$ALLOW_NETWORK" = "true" ]
    [ "$ALLOW_DOCKER" = "true" ]
    [ "$SKIP_DOCKER_AUTODETECT" = "false" ]
}

@test "load_config accepts key name aliases in user config" {
    cat > "$HOME/.config/clsecure/config" << EOF
isolation_mode = container
allow_network = false
allow_docker = true
INSTALL_DEPS = true
EOF

    _reinit
    load_config
    [ "$ISOLATION_MODE" = "container" ]
    [ "$ALLOW_NETWORK" = "false" ]
    [ "$ALLOW_DOCKER" = "true" ]
    [ "$INSTALL_DEPS" = "true" ]
}

@test "_trim strips leading and trailing whitespace" {
    local result
    result=$(_trim "  hello  ")
    [ "$result" = "hello" ]
}

@test "_trim handles empty string" {
    local result
    result=$(_trim "")
    [ "$result" = "" ]
}

@test "_is_valid_config_value validates mode" {
    _is_valid_config_value "mode" "user"
    _is_valid_config_value "mode" "namespace"
    _is_valid_config_value "mode" "container"
    ! _is_valid_config_value "mode" "invalid"
    ! _is_valid_config_value "mode" ""
}

@test "_is_valid_config_value validates booleans" {
    _is_valid_config_value "docker" "true"
    _is_valid_config_value "docker" "false"
    _is_valid_config_value "docker" "yes"
    _is_valid_config_value "docker" "no"
    _is_valid_config_value "docker" "1"
    _is_valid_config_value "docker" "0"
    ! _is_valid_config_value "docker" "maybe"
}

@test "_is_valid_config_value validates cleanup_hook_timeout" {
    _is_valid_config_value "cleanup_hook_timeout" "5"
    _is_valid_config_value "cleanup_hook_timeout" "300"
    ! _is_valid_config_value "cleanup_hook_timeout" "3"
    ! _is_valid_config_value "cleanup_hook_timeout" "500"
    ! _is_valid_config_value "cleanup_hook_timeout" "abc"
}

# --- Provider config ---

@test "load_config reads provider from user config" {
    cat > "$HOME/.config/clsecure/config" << EOF
provider = kimi
kimi_api_key = sk-kimi-test123
EOF

    _reinit
    load_config
    [ "$PROVIDER" = "kimi" ]
    [ "$KIMI_API_KEY" = "sk-kimi-test123" ]
}

@test "load_config normalizes provider=anthropic to empty" {
    cat > "$HOME/.config/clsecure/config" << EOF
provider = anthropic
EOF

    _reinit
    load_config
    [ "$PROVIDER" = "" ]
}

@test "load_config warns on invalid provider value" {
    cat > "$HOME/.config/clsecure/config" << EOF
provider = openai
EOF

    _reinit
    run load_config
    [[ "$output" == *"Invalid provider"* ]]
    [[ "$output" == *"openai"* ]]
}

@test "load_config ignores provider from project config" {
    rm -f "$HOME/.config/clsecure/config"
    rm -f "$HOME/.clsecurerc"

    mkdir -p "$TEST_DIR/.clsecure"
    cat > "$TEST_DIR/.clsecure/config" << EOF
provider = kimi
EOF

    _reinit
    load_config
    [ "$PROVIDER" = "" ]
}

@test "load_config warns on provider in project config" {
    rm -f "$HOME/.config/clsecure/config"
    rm -f "$HOME/.clsecurerc"

    mkdir -p "$TEST_DIR/.clsecure"
    cat > "$TEST_DIR/.clsecure/config" << EOF
provider = kimi
EOF

    _reinit
    run load_config
    [[ "$output" == *"ignored"* ]]
    [[ "$output" == *"provider"* ]]
}

@test "load_config ignores kimi_api_key from project config" {
    rm -f "$HOME/.config/clsecure/config"
    rm -f "$HOME/.clsecurerc"

    mkdir -p "$TEST_DIR/.clsecure"
    cat > "$TEST_DIR/.clsecure/config" << EOF
kimi_api_key = sk-kimi-evil
EOF

    _reinit
    load_config
    [ "$KIMI_API_KEY" = "" ]
}

@test "load_config warns on kimi_api_key in project config" {
    rm -f "$HOME/.config/clsecure/config"
    rm -f "$HOME/.clsecurerc"

    mkdir -p "$TEST_DIR/.clsecure"
    cat > "$TEST_DIR/.clsecure/config" << EOF
kimi_api_key = sk-kimi-evil
EOF

    _reinit
    run load_config
    [[ "$output" == *"ignored"* ]]
    [[ "$output" == *"kimi_api_key"* ]]
}

@test "_is_valid_config_value validates provider" {
    _is_valid_config_value "provider" "kimi"
    _is_valid_config_value "provider" "anthropic"
    ! _is_valid_config_value "provider" "openai"
    ! _is_valid_config_value "provider" ""
}

@test "_is_valid_config_value validates kimi_api_key" {
    _is_valid_config_value "kimi_api_key" "sk-kimi-test"
    ! _is_valid_config_value "kimi_api_key" ""
}

@test "KIMI_API_KEY env var preserved through init" {
    export KIMI_API_KEY="sk-kimi-from-env"
    _reinit
    [ "$KIMI_API_KEY" = "sk-kimi-from-env" ]
    unset KIMI_API_KEY
}

@test "show_config_info displays provider and kimi_api_key" {
    PROVIDER="kimi"
    KIMI_API_KEY="sk-kimi-test123456789"
    run show_config_info
    [ "$status" -eq 0 ]
    [[ "$output" == *"provider = kimi"* ]]
    [[ "$output" == *"kimi_api_key = sk-kimi-te..."* ]]
}
