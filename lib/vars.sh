#!/bin/bash
# lib/vars.sh
# 
# Global variable initialization for clsecure
# 
# Dependencies: None
# Exports: All clsecure global variables
# 
# Usage:
#   source lib/vars.sh
#   init_clsecure_vars

# Initialize all global variables for clsecure
init_clsecure_vars() {
    # Core variables
    WORKER_PREFIX="claude-worker"
    CURRENT_DIR=$(pwd)
    PROJECT_NAME=$(basename "$CURRENT_DIR")

    # Sanitize project name for username (lowercase, alphanumeric + dash)
    # Add hash suffix to avoid collisions when project names are truncated
    # Linux username limit is 32 chars: "claude-worker" (14 chars) + "-" (1) + project (max 17 chars) = 32 total
    PROJECT_NAME_SANITIZED=$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')
    
    # Generate short hash from full directory path to ensure uniqueness
    # Use full path to handle projects with same name in different locations
    if command -v sha256sum &>/dev/null; then
        PROJECT_HASH=$(echo -n "$CURRENT_DIR" | sha256sum | cut -c1-6)
    elif command -v shasum &>/dev/null; then
        PROJECT_HASH=$(echo -n "$CURRENT_DIR" | shasum -a 256 | cut -c1-6)
    else
        # Fallback: use first 6 chars of md5sum if available, otherwise use simple hash
        if command -v md5sum &>/dev/null; then
            PROJECT_HASH=$(echo -n "$CURRENT_DIR" | md5sum | cut -c1-6)
        else
            # Last resort: use first 6 chars of sanitized path
            PROJECT_HASH=$(echo -n "$CURRENT_DIR" | tr -cd 'a-z0-9' | cut -c1-6)
            [ -z "$PROJECT_HASH" ] && PROJECT_HASH="000000"
        fi
    fi
    
    # Combine: first 10 chars of name + dash + 6 char hash = 17 chars total
    # "claude-worker" (14) + "-" (1) + project (17) = 32 chars (fits Linux username limit)
    SAFE_PROJECT_NAME="${PROJECT_NAME_SANITIZED:0:10}-${PROJECT_HASH}"
    WORKER_USER="${WORKER_PREFIX}-${SAFE_PROJECT_NAME}"
    WORKER_HOME="/home/$WORKER_USER"
    WORKER_PROJECT="$WORKER_HOME/project"

    # Lock file
    LOCK_DIR="/tmp/claude-secure-locks"
    LOCK_FILE="$LOCK_DIR/${WORKER_USER}.lock"

    # Default isolation settings (can be overridden by config file and CLI args)
    ISOLATION_MODE="namespace"  # Options: user, namespace, container
    ALLOW_NETWORK=true
    ALLOW_DOCKER=false
    INSTALL_DEPS=false
    SETUP_SCRIPT=""
    SHELL_ONLY=false  # If true, drop into shell instead of running Claude
    SKIP_SETUP=false  # If true, skip setup script execution
    FULL_CLONE=false  # If true, clone full git history (slower)

    # Config file locations (XDG standard, then fallback)
    CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/clsecure/config"
    CONFIG_FILE_ALT="$HOME/.clsecurerc"

    # Colors
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    NC='\033[0m'

    # Export variables that modules need
    export WORKER_USER WORKER_HOME WORKER_PROJECT
    export ISOLATION_MODE ALLOW_NETWORK ALLOW_DOCKER INSTALL_DEPS SETUP_SCRIPT SHELL_ONLY SKIP_SETUP FULL_CLONE
    export LOCK_FILE LOCK_DIR
    export CONFIG_FILE CONFIG_FILE_ALT
    export RED GREEN YELLOW BLUE CYAN NC
    export WORKER_PREFIX CURRENT_DIR PROJECT_NAME PROJECT_NAME_SANITIZED PROJECT_HASH SAFE_PROJECT_NAME
}
