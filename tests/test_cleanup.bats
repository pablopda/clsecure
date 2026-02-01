#!/usr/bin/env bats
# test_cleanup.bats
#
# Tests for lib/cleanup.sh

load test_helpers

# Shared sudo mock that handles test, readlink, -u, pkill, pgrep patterns
_mock_sudo() {
    sudo() {
        case "$1" in
            test)
                shift
                command test "$@"
                ;;
            readlink)
                shift
                command readlink "$@"
                ;;
            pgrep)
                shift
                command pgrep "$@"
                ;;
            pkill)
                # Record pkill calls for verification
                echo "pkill $*" >> "${TEST_DIR}/.pkill_calls"
                return 0
                ;;
            -u)
                # sudo -u USER cmd args...
                shift  # -u
                shift  # USER
                "$@"
                ;;
            *)
                "$@"
                ;;
        esac
    }
    export -f sudo
}

# Mock pgrep to simulate no running processes
_mock_pgrep_none() {
    pgrep() { return 1; }
    export -f pgrep
    sudo() {
        case "$1" in
            pgrep) return 1 ;;
            pkill) echo "pkill $*" >> "${TEST_DIR}/.pkill_calls"; return 0 ;;
            test) shift; command test "$@" ;;
            readlink) shift; command readlink "$@" ;;
            -u) shift; shift; "$@" ;;
            *) "$@" ;;
        esac
    }
    export -f sudo
}

# Mock pgrep to simulate processes that die after SIGTERM
_mock_pgrep_dies_after_term() {
    # Use a file counter to track pgrep calls
    echo "0" > "${TEST_DIR}/.pgrep_count"
    sudo() {
        case "$1" in
            pgrep)
                local count
                count=$(cat "${TEST_DIR}/.pgrep_count")
                count=$((count + 1))
                echo "$count" > "${TEST_DIR}/.pgrep_count"
                # First call: processes exist; subsequent calls: gone
                if [ "$count" -le 1 ]; then
                    return 0
                else
                    return 1
                fi
                ;;
            pkill)
                echo "pkill $*" >> "${TEST_DIR}/.pkill_calls"
                return 0
                ;;
            test) shift; command test "$@" ;;
            readlink) shift; command readlink "$@" ;;
            -u) shift; shift; "$@" ;;
            *) "$@" ;;
        esac
    }
    export -f sudo
}


setup() {
    setup_test
    source_module "vars.sh"
    init_clsecure_vars
    source_module "logging.sh"
    source_module "cleanup.sh"

    # Override WORKER_PROJECT to a temp directory we control
    export WORKER_PROJECT="$TEST_DIR/project"
    export WORKER_USER="test-worker-cleanup"
    export WORKER_HOME="/home/test-worker-cleanup"
    export ALLOW_DOCKER=false
    export SKIP_DOCKER_AUTODETECT=false
    export CLEANUP_HOOK_TIMEOUT=30
    export SESSION_NAME=""
    mkdir -p "$WORKER_PROJECT"

    # Clean up pkill call log
    rm -f "${TEST_DIR}/.pkill_calls"
}

teardown() {
    teardown_test
}

# ---------------------------------------------------------------------------
# Function existence checks
# ---------------------------------------------------------------------------

@test "cleanup_session function exists" {
    assert_function_exists cleanup_session
}

@test "kill_worker_processes function exists" {
    assert_function_exists kill_worker_processes
}

@test "validate_cleanup_hook function exists" {
    assert_function_exists validate_cleanup_hook
}

@test "run_cleanup_hook function exists" {
    assert_function_exists run_cleanup_hook
}

@test "auto_detect_docker_cleanup function exists" {
    assert_function_exists auto_detect_docker_cleanup
}

# ---------------------------------------------------------------------------
# cleanup_session guard
# ---------------------------------------------------------------------------

@test "cleanup_session returns early when WORKER_USER is empty" {
    export WORKER_USER=""
    run cleanup_session "stop"
    [ "$status" -eq 0 ]
    [[ "$output" == *"worker variables not set"* ]]
}

@test "cleanup_session returns early when WORKER_PROJECT is empty" {
    export WORKER_PROJECT=""
    run cleanup_session "stop"
    [ "$status" -eq 0 ]
    [[ "$output" == *"worker variables not set"* ]]
}

# ---------------------------------------------------------------------------
# validate_cleanup_hook
# ---------------------------------------------------------------------------

@test "validate_cleanup_hook returns 1 when no hook exists" {
    _mock_sudo
    run validate_cleanup_hook
    [ "$status" -eq 1 ]
}

@test "validate_cleanup_hook returns 0 when valid hook exists" {
    mkdir -p "$WORKER_PROJECT/.clsecure"
    cat > "$WORKER_PROJECT/.clsecure/on-cleanup" << 'EOF'
#!/bin/bash
echo "cleanup"
EOF
    chmod +x "$WORKER_PROJECT/.clsecure/on-cleanup"
    _mock_sudo

    run validate_cleanup_hook
    [ "$status" -eq 0 ]
}

@test "validate_cleanup_hook returns 1 for non-executable hook" {
    mkdir -p "$WORKER_PROJECT/.clsecure"
    echo "#!/bin/bash" > "$WORKER_PROJECT/.clsecure/on-cleanup"
    # Not executable
    _mock_sudo

    run validate_cleanup_hook
    [ "$status" -eq 1 ]
}

@test "validate_cleanup_hook returns 1 for symlink outside project" {
    mkdir -p "$WORKER_PROJECT/.clsecure"
    echo '#!/bin/bash' > "$TEST_DIR/outside-script.sh"
    chmod +x "$TEST_DIR/outside-script.sh"
    ln -s "$TEST_DIR/outside-script.sh" "$WORKER_PROJECT/.clsecure/on-cleanup"
    _mock_sudo

    run validate_cleanup_hook
    [ "$status" -eq 1 ]
    [[ "$output" == *"symlinks outside project directory"* ]]
}

@test "validate_cleanup_hook returns 1 when readlink fails" {
    mkdir -p "$WORKER_PROJECT/.clsecure"
    cat > "$WORKER_PROJECT/.clsecure/on-cleanup" << 'EOF'
#!/bin/bash
echo "cleanup"
EOF
    chmod +x "$WORKER_PROJECT/.clsecure/on-cleanup"

    # Mock sudo where readlink always fails
    sudo() {
        case "$1" in
            test) shift; command test "$@" ;;
            readlink) return 1 ;;
            *) "$@" ;;
        esac
    }
    export -f sudo

    run validate_cleanup_hook
    [ "$status" -eq 1 ]
    [[ "$output" == *"Cannot resolve cleanup hook path"* ]]
}

# ---------------------------------------------------------------------------
# run_cleanup_hook
# ---------------------------------------------------------------------------

@test "run_cleanup_hook executes hook and returns 0 on success" {
    mkdir -p "$WORKER_PROJECT/.clsecure"
    cat > "$WORKER_PROJECT/.clsecure/on-cleanup" << 'HOOKEOF'
#!/bin/bash
echo "hook ran successfully"
HOOKEOF
    chmod +x "$WORKER_PROJECT/.clsecure/on-cleanup"

    # Mock sudo -u to just run the command (skip user switch)
    sudo() {
        if [ "$1" = "-u" ]; then
            shift; shift  # skip -u USERNAME
            "$@"
        else
            "$@"
        fi
    }
    export -f sudo

    run run_cleanup_hook "stop"
    [ "$status" -eq 0 ]
    [[ "$output" == *"hook ran"* ]]
}

@test "run_cleanup_hook returns 0 even when hook exits non-zero" {
    mkdir -p "$WORKER_PROJECT/.clsecure"
    cat > "$WORKER_PROJECT/.clsecure/on-cleanup" << 'HOOKEOF'
#!/bin/bash
exit 42
HOOKEOF
    chmod +x "$WORKER_PROJECT/.clsecure/on-cleanup"

    sudo() {
        if [ "$1" = "-u" ]; then
            shift; shift
            "$@"
        else
            "$@"
        fi
    }
    export -f sudo

    run run_cleanup_hook "stop"
    [ "$status" -eq 0 ]
    [[ "$output" == *"exited with code 42"* ]]
}

@test "run_cleanup_hook passes correct environment variables" {
    export SESSION_NAME="test-session"
    export WORKER_HOME="/home/test-worker-cleanup"
    mkdir -p "$WORKER_PROJECT/.clsecure"
    cat > "$WORKER_PROJECT/.clsecure/on-cleanup" << 'HOOKEOF'
#!/bin/bash
echo "SESSION=$CLSECURE_SESSION"
echo "LEVEL=$CLSECURE_CLEANUP_LEVEL"
echo "DIR=$CLSECURE_PROJECT_DIR"
echo "USER=$CLSECURE_WORKER_USER"
echo "HOME=$CLSECURE_WORKER_HOME"
HOOKEOF
    chmod +x "$WORKER_PROJECT/.clsecure/on-cleanup"

    sudo() {
        if [ "$1" = "-u" ]; then
            shift; shift
            "$@"
        else
            "$@"
        fi
    }
    export -f sudo

    run run_cleanup_hook "purge"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SESSION=test-session"* ]]
    [[ "$output" == *"LEVEL=purge"* ]]
    [[ "$output" == *"DIR=$WORKER_PROJECT"* ]]
    [[ "$output" == *"USER=$WORKER_USER"* ]]
    [[ "$output" == *"HOME=$WORKER_HOME"* ]]
}

@test "run_cleanup_hook logs warning on timeout (exit 124)" {
    mkdir -p "$WORKER_PROJECT/.clsecure"
    # Create a hook that exits immediately (we mock the exit code)
    cat > "$WORKER_PROJECT/.clsecure/on-cleanup" << 'HOOKEOF'
#!/bin/bash
echo "running"
HOOKEOF
    chmod +x "$WORKER_PROJECT/.clsecure/on-cleanup"

    # Mock sudo to always return 124 (timeout)
    sudo() {
        if [ "$1" = "-u" ]; then
            return 124
        else
            "$@"
        fi
    }
    export -f sudo

    run run_cleanup_hook "stop"
    [ "$status" -eq 0 ]
    [[ "$output" == *"timed out"* ]]
}

# ---------------------------------------------------------------------------
# auto_detect_docker_cleanup
# ---------------------------------------------------------------------------

@test "auto_detect_docker_cleanup is a no-op when no compose file exists" {
    export ALLOW_DOCKER=true
    export SKIP_DOCKER_AUTODETECT=false
    _mock_sudo

    run auto_detect_docker_cleanup "stop"
    [ "$status" -eq 0 ]
    # Should not contain "Auto-detected" since no compose file
    [[ "$output" != *"Auto-detected"* ]]
}

@test "auto_detect_docker_cleanup is a no-op when docker command not found" {
    export ALLOW_DOCKER=true
    export SKIP_DOCKER_AUTODETECT=false

    # Create compose file
    touch "$WORKER_PROJECT/docker-compose.yml"

    # Mock docker as not found
    command() {
        if [ "$1" = "-v" ] && [ "$2" = "docker" ]; then
            return 1
        fi
        builtin command "$@"
    }
    export -f command

    _mock_sudo

    run auto_detect_docker_cleanup "stop"
    [ "$status" -eq 0 ]
    [[ "$output" != *"Auto-detected"* ]]
}

@test "auto_detect_docker_cleanup detects docker-compose.yml" {
    export ALLOW_DOCKER=true
    export SKIP_DOCKER_AUTODETECT=false
    touch "$WORKER_PROJECT/docker-compose.yml"

    # Mock sudo and docker
    sudo() {
        case "$1" in
            test) shift; command test "$@" ;;
            -u)
                # Record the docker command that would be run
                shift; shift  # -u USER
                echo "DOCKER_CMD: $*" >> "${TEST_DIR}/.docker_calls"
                return 0
                ;;
            *) "$@" ;;
        esac
    }
    export -f sudo

    run auto_detect_docker_cleanup "stop"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Auto-detected docker-compose.yml"* ]]

    # Verify docker compose down was called (not purge flags)
    [ -f "${TEST_DIR}/.docker_calls" ]
    local docker_cmd
    docker_cmd=$(cat "${TEST_DIR}/.docker_calls")
    [[ "$docker_cmd" == *"docker compose down"* ]]
    [[ "$docker_cmd" != *"-v"* ]]
}

@test "auto_detect_docker_cleanup uses purge flags for purge level" {
    export ALLOW_DOCKER=true
    export SKIP_DOCKER_AUTODETECT=false
    touch "$WORKER_PROJECT/compose.yaml"

    sudo() {
        case "$1" in
            test) shift; command test "$@" ;;
            -u)
                shift; shift
                echo "DOCKER_CMD: $*" >> "${TEST_DIR}/.docker_calls"
                return 0
                ;;
            *) "$@" ;;
        esac
    }
    export -f sudo

    run auto_detect_docker_cleanup "purge"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Auto-detected compose.yaml"* ]]

    local docker_cmd
    docker_cmd=$(cat "${TEST_DIR}/.docker_calls")
    [[ "$docker_cmd" == *"-v --remove-orphans"* ]]
}

@test "auto_detect_docker_cleanup logs warning on docker failure" {
    export ALLOW_DOCKER=true
    export SKIP_DOCKER_AUTODETECT=false
    touch "$WORKER_PROJECT/docker-compose.yml"

    sudo() {
        case "$1" in
            test) shift; command test "$@" ;;
            -u)
                # Simulate docker compose failure
                return 1
                ;;
            *) "$@" ;;
        esac
    }
    export -f sudo

    run auto_detect_docker_cleanup "stop"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Docker compose cleanup failed"* ]]
}

# ---------------------------------------------------------------------------
# kill_worker_processes
# ---------------------------------------------------------------------------

@test "kill_worker_processes returns early when no processes exist" {
    _mock_pgrep_none

    run kill_worker_processes
    [ "$status" -eq 0 ]
    # Should NOT contain "Terminating" since no processes found
    [[ "$output" != *"Terminating"* ]]
    # pkill should not have been called
    [ ! -f "${TEST_DIR}/.pkill_calls" ]
}

@test "kill_worker_processes sends SIGTERM and processes die" {
    _mock_pgrep_dies_after_term
    sleep() { :; }
    export -f sleep

    run kill_worker_processes
    [ "$status" -eq 0 ]
    [[ "$output" == *"Terminating"* ]]

    # Verify SIGTERM was sent
    [ -f "${TEST_DIR}/.pkill_calls" ]
    grep -q "pkill -TERM" "${TEST_DIR}/.pkill_calls"
    # SIGKILL should NOT have been sent (processes died after TERM)
    ! grep -q "pkill -KILL" "${TEST_DIR}/.pkill_calls"
}

@test "kill_worker_processes escalates to SIGKILL when processes survive" {
    # Mock: pgrep always finds processes, pkill is recorded, sleep is a no-op
    sudo() {
        case "$1" in
            pgrep) return 0 ;;  # Always "processes exist"
            pkill) echo "pkill $*" >> "${TEST_DIR}/.pkill_calls"; return 0 ;;
            *) "$@" ;;
        esac
    }
    export -f sudo
    sleep() { :; }
    export -f sleep

    run kill_worker_processes
    [ "$status" -eq 0 ]
    [[ "$output" == *"Terminating"* ]]
    [[ "$output" == *"SIGKILL"* ]]

    # Verify both SIGTERM and SIGKILL were sent
    [ -f "${TEST_DIR}/.pkill_calls" ]
    grep -q "pkill -TERM" "${TEST_DIR}/.pkill_calls"
    grep -q "pkill -KILL" "${TEST_DIR}/.pkill_calls"
}

# ---------------------------------------------------------------------------
# cleanup_session full flows
# ---------------------------------------------------------------------------

@test "cleanup_session runs without error when no hook and no docker" {
    export ALLOW_DOCKER=false
    export SKIP_DOCKER_AUTODETECT=false
    _mock_pgrep_none

    run cleanup_session "stop"
    [ "$status" -eq 0 ]
}

@test "cleanup_session calls hook when valid hook exists" {
    mkdir -p "$WORKER_PROJECT/.clsecure"
    cat > "$WORKER_PROJECT/.clsecure/on-cleanup" << 'HOOKEOF'
#!/bin/bash
echo "HOOK_EXECUTED"
HOOKEOF
    chmod +x "$WORKER_PROJECT/.clsecure/on-cleanup"

    # Mock sudo for both validation and execution
    sudo() {
        case "$1" in
            test) shift; command test "$@" ;;
            readlink) shift; command readlink "$@" ;;
            pgrep) return 1 ;;
            pkill) return 0 ;;
            -u) shift; shift; "$@" ;;
            *) "$@" ;;
        esac
    }
    export -f sudo

    run cleanup_session "stop"
    [ "$status" -eq 0 ]
    [[ "$output" == *"HOOK_EXECUTED"* ]]
}

@test "cleanup_session skips docker autodetect when SKIP_DOCKER_AUTODETECT=true" {
    export ALLOW_DOCKER=true
    export SKIP_DOCKER_AUTODETECT=true
    touch "$WORKER_PROJECT/docker-compose.yml"
    _mock_pgrep_none

    run cleanup_session "stop"
    [ "$status" -eq 0 ]
    # Should NOT auto-detect docker
    [[ "$output" != *"Auto-detected"* ]]
}

@test "cleanup_session falls back to docker autodetect when no hook exists" {
    export ALLOW_DOCKER=true
    export SKIP_DOCKER_AUTODETECT=false
    touch "$WORKER_PROJECT/docker-compose.yml"

    sudo() {
        case "$1" in
            test) shift; command test "$@" ;;
            readlink) shift; command readlink "$@" ;;
            pgrep) return 1 ;;
            pkill) return 0 ;;
            -u)
                shift; shift
                echo "DOCKER_CMD: $*" >> "${TEST_DIR}/.docker_calls"
                return 0
                ;;
            *) "$@" ;;
        esac
    }
    export -f sudo

    run cleanup_session "purge"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Auto-detected docker-compose.yml"* ]]
}
