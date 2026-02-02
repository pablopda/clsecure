#!/usr/bin/env bash
# test_helpers.bash
# 
# Common test utilities for clsecure module tests

# Load bats if available, otherwise skip
if ! command -v bats &>/dev/null; then
    echo "Warning: bats not installed. Install with: sudo apt install bats"
    exit 0
fi

# Resolve the project lib directory (before any cd to temp dirs)
CLSECURE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"

# Test setup: Create temporary directory
setup_test() {
    TEST_DIR=$(mktemp -d)
    export TEST_DIR
    cd "$TEST_DIR" || exit 1
}

# Test teardown: Clean up temporary directory
teardown_test() {
    if [ -n "${TEST_DIR:-}" ] && [ -d "$TEST_DIR" ]; then
        rm -rf "$TEST_DIR"
    fi
}

# Source a module for testing (with mocked dependencies)
source_module() {
    local module="$1"
    local lib_dir="${2:-$CLSECURE_LIB_DIR}"
    
    # Create a temporary directory for the module
    local temp_lib=$(mktemp -d)
    
    # Copy the module
    cp "$lib_dir/$module" "$temp_lib/"
    
    # Source vars.sh first if not already sourced
    if [ "$module" != "vars.sh" ] && ! declare -f init_clsecure_vars &>/dev/null; then
        source "$lib_dir/vars.sh"
        # Mock variables for testing
        export WORKER_PREFIX="test-worker"
        export CURRENT_DIR="$TEST_DIR"
        export PROJECT_NAME="test-project"
        export PROJECT_NAME_SANITIZED="test-project"
        export PROJECT_HASH="abc123"
        export SAFE_PROJECT_NAME="test-project"
        export WORKER_USER="test-worker-test-project"
        export WORKER_HOME="/home/test-worker-test-project"
        export WORKER_PROJECT="$WORKER_HOME/test-project"
        export LOCK_DIR="/tmp/clsecure-locks"
        export LOCK_FILE="$LOCK_DIR/test-project.lock"
        export ISOLATION_MODE="user"
        export ALLOW_NETWORK=true
        export ALLOW_DOCKER=false
        export INSTALL_DEPS=false
        export SETUP_SCRIPT=""
        export CONFIG_FILE="$HOME/.config/clsecure/config"
        export CONFIG_FILE_ALT="$HOME/.clsecurerc"
        export PROJECT_CONFIG_FILE="$CURRENT_DIR/.clsecure/config"
        export RED='\033[0;31m'
        export GREEN='\033[0;32m'
        export YELLOW='\033[1;33m'
        export BLUE='\033[0;34m'
        export CYAN='\033[0;36m'
        export NC='\033[0m'
    fi
    
    # Source logging.sh if needed
    if [ "$module" != "logging.sh" ] && ! declare -f log_info &>/dev/null; then
        source "$lib_dir/logging.sh" 2>/dev/null || true
    fi
    
    # Source the requested module
    source "$temp_lib/$module"
    
    # Cleanup
    rm -rf "$temp_lib"
}

# Mock functions for testing
mock_sudo() {
    sudo() {
        "$@"
    }
}

# Assert that a function exists
assert_function_exists() {
    local func_name="$1"
    if ! declare -f "$func_name" &>/dev/null; then
        echo "Function $func_name does not exist"
        return 1
    fi
}

# Assert that a variable is set
assert_variable_set() {
    local var_name="$1"
    if [ -z "${!var_name:-}" ]; then
        echo "Variable $var_name is not set"
        return 1
    fi
}
