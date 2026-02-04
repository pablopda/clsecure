#!/usr/bin/env bats
# test_sanitize.bats
#
# Tests for lib/sanitize.sh

load test_helpers

setup() {
    setup_test
    source_module "vars.sh"
    init_clsecure_vars
    source_module "logging.sh"
    source_module "worker.sh"
    source_module "sanitize.sh"

    # Override WORKER_PROJECT to a temp directory we control
    WORKER_PROJECT="$TEST_DIR/project"
    mkdir -p "$WORKER_PROJECT/.claude"

    # Mock sudo to strip -u <user> flags and handle VAR=val cmd args
    sudo() {
        if [ "$1" = "-u" ]; then
            shift 2  # drop -u <user>
        fi
        # Collect leading VAR=val assignments
        local -a envs=()
        while [[ "${1:-}" == *=* && "${1%%=*}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; do
            envs+=("$1")
            shift
        done
        if [ ${#envs[@]} -gt 0 ]; then
            env "${envs[@]}" "$@"
        else
            command "$@"
        fi
    }
}

teardown() {
    teardown_test
}

# --- Function existence tests ---

@test "sanitize_mcp_config function exists" {
    assert_function_exists sanitize_mcp_config
}

@test "sanitize_worker_claude_home_paths function exists" {
    assert_function_exists sanitize_worker_claude_home_paths
}

@test "check_worker_mcp_runtime function exists" {
    assert_function_exists check_worker_mcp_runtime
}

@test "sanitize_hook_relative_paths function exists" {
    assert_function_exists sanitize_hook_relative_paths
}

# --- Guard condition tests ---

@test "sanitize_hook_relative_paths returns 0 when settings.json missing" {
    rm -f "$WORKER_PROJECT/.claude/settings.json"
    run sanitize_hook_relative_paths
    [ "$status" -eq 0 ]
}

@test "sanitize_hook_relative_paths returns 0 when no hooks key" {
    cat > "$WORKER_PROJECT/.claude/settings.json" <<'EOF'
{
  "permissions": {}
}
EOF
    run sanitize_hook_relative_paths
    [ "$status" -eq 0 ]
    # File should be unchanged
    run cat "$WORKER_PROJECT/.claude/settings.json"
    [[ "$output" == *'"permissions"'* ]]
    [[ "$output" != *'hooks'* ]]
}

@test "sanitize_hook_relative_paths returns 0 on invalid JSON" {
    echo "not valid json {{{" > "$WORKER_PROJECT/.claude/settings.json"
    run sanitize_hook_relative_paths
    [ "$status" -eq 0 ]
    # File should be unchanged
    run cat "$WORKER_PROJECT/.claude/settings.json"
    [[ "$output" == "not valid json {{{" ]]
}

@test "sanitize_hook_relative_paths returns 0 when no ./ paths present" {
    cat > "$WORKER_PROJECT/.claude/settings.json" <<'EOF'
{
  "hooks": {
    "PreToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "echo hello"
          }
        ]
      }
    ]
  }
}
EOF
    run sanitize_hook_relative_paths
    [ "$status" -eq 0 ]
    # File should be unchanged (no rewrite when nothing matches)
    run cat "$WORKER_PROJECT/.claude/settings.json"
    [[ "$output" == *'"echo hello"'* ]]
}

# --- Core logic tests ---

@test "sanitize_hook_relative_paths rewrites ./ at start of command" {
    cat > "$WORKER_PROJECT/.claude/settings.json" <<EOF
{
  "hooks": {
    "PreToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "./scripts/lint.sh"
          }
        ]
      }
    ]
  }
}
EOF
    run sanitize_hook_relative_paths
    [ "$status" -eq 0 ]
    run cat "$WORKER_PROJECT/.claude/settings.json"
    [[ "$output" == *"$WORKER_PROJECT/scripts/lint.sh"* ]]
    # Must not contain "./" prefix anymore
    [[ "$output" != *'"./scripts'* ]]
}

@test "sanitize_hook_relative_paths rewrites ./ as argument" {
    cat > "$WORKER_PROJECT/.claude/settings.json" <<EOF
{
  "hooks": {
    "PreToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "python3 ./.claude/tools/auto-format.py"
          }
        ]
      }
    ]
  }
}
EOF
    run sanitize_hook_relative_paths
    [ "$status" -eq 0 ]
    run cat "$WORKER_PROJECT/.claude/settings.json"
    [[ "$output" == *"python3 $WORKER_PROJECT/.claude/tools/auto-format.py"* ]]
}

@test "sanitize_hook_relative_paths rewrites multiple ./ in same command" {
    cat > "$WORKER_PROJECT/.claude/settings.json" <<EOF
{
  "hooks": {
    "PreToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "./run.sh --config ./.claude/config.json"
          }
        ]
      }
    ]
  }
}
EOF
    run sanitize_hook_relative_paths
    [ "$status" -eq 0 ]
    run cat "$WORKER_PROJECT/.claude/settings.json"
    [[ "$output" == *"$WORKER_PROJECT/run.sh --config $WORKER_PROJECT/.claude/config.json"* ]]
}

@test "sanitize_hook_relative_paths handles multiple hook events" {
    cat > "$WORKER_PROJECT/.claude/settings.json" <<EOF
{
  "hooks": {
    "PreToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "./pre-tool.sh"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "./post-tool.sh"
          }
        ]
      }
    ]
  }
}
EOF
    run sanitize_hook_relative_paths
    [ "$status" -eq 0 ]
    run cat "$WORKER_PROJECT/.claude/settings.json"
    [[ "$output" == *"$WORKER_PROJECT/pre-tool.sh"* ]]
    [[ "$output" == *"$WORKER_PROJECT/post-tool.sh"* ]]
}

# --- Selective behavior tests ---

@test "sanitize_hook_relative_paths skips non-command hook types" {
    cat > "$WORKER_PROJECT/.claude/settings.json" <<EOF
{
  "hooks": {
    "PreToolUse": [
      {
        "hooks": [
          {
            "type": "prompt",
            "command": "./should-not-change.sh"
          }
        ]
      }
    ]
  }
}
EOF
    run sanitize_hook_relative_paths
    [ "$status" -eq 0 ]
    run cat "$WORKER_PROJECT/.claude/settings.json"
    [[ "$output" == *'"./should-not-change.sh"'* ]]
}

@test "sanitize_hook_relative_paths preserves ../ paths" {
    cat > "$WORKER_PROJECT/.claude/settings.json" <<EOF
{
  "hooks": {
    "PreToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "../scripts/lint.sh"
          }
        ]
      }
    ]
  }
}
EOF
    run sanitize_hook_relative_paths
    [ "$status" -eq 0 ]
    run cat "$WORKER_PROJECT/.claude/settings.json"
    [[ "$output" == *'"../scripts/lint.sh"'* ]]
}

@test "sanitize_hook_relative_paths preserves non-hook fields" {
    cat > "$WORKER_PROJECT/.claude/settings.json" <<EOF
{
  "permissions": {
    "allow": ["./foo"]
  },
  "hooks": {
    "PreToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "./rewrite-me.sh"
          }
        ]
      }
    ]
  }
}
EOF
    run sanitize_hook_relative_paths
    [ "$status" -eq 0 ]
    run cat "$WORKER_PROJECT/.claude/settings.json"
    # Hook command should be rewritten
    [[ "$output" == *"$WORKER_PROJECT/rewrite-me.sh"* ]]
    # Non-hook field should be preserved as-is
    [[ "$output" == *'"./foo"'* ]]
}
