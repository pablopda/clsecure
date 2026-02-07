#!/bin/bash
# lib/git.sh
# 
# Git operations for clsecure
# 
# Dependencies: lib/logging.sh, lib/worker.sh, lib/vars.sh
# Exports: check_disk_space, clone_repository, sync_working_directory, copy_submodules, setup_git_config, copy_git_hooks
# 
# Usage:
#   source lib/git.sh
#   clone_repository

# Check available disk space before cloning
check_disk_space() {
    local required_mb="${1:-1000}"  # Default: 1GB minimum
    if command -v df &>/dev/null; then
        local available_space=$(df -m "$WORKER_HOME" 2>/dev/null | tail -1 | awk '{print $4}' || echo "0")
        if [ "$available_space" -lt "$required_mb" ] 2>/dev/null; then
            log_error "Insufficient disk space (need ${required_mb}MB, have ${available_space}MB)"
            log_info "Free up space or use a different location"
            return 1
        fi
    fi
    return 0
}

# Clone repository to worker project directory
# Uses shallow clone (50 commits) by default; set FULL_CLONE=true for full history
clone_repository() {
    sudo rm -rf "$WORKER_PROJECT" 2>/dev/null || true

    if [ "${FULL_CLONE:-false}" = true ]; then
        log_info "Cloning repository (full history)..."
        if ! sudo git clone --no-hardlinks --quiet "$CURRENT_DIR" "$WORKER_PROJECT"; then
            log_error "Failed to clone repository"
            return 1
        fi
    else
        log_info "Cloning repository (last 50 commits)..."
        # Use file:// protocol to enable --depth for local repos
        # 50 commits gives enough history for git log/blame while being fast
        if ! sudo git clone --quiet --depth 50 "file://$CURRENT_DIR" "$WORKER_PROJECT"; then
            log_error "Failed to clone repository"
            return 1
        fi
    fi
    return 0
}

# Sync working directory files (rsync)
sync_working_directory() {
    log_info "Syncing working directory..."
    sudo rsync -a \
        --exclude='.git' \
        --exclude='node_modules' \
        --exclude='venv' \
        --exclude='.venv' \
        --exclude='__pycache__' \
        --exclude='.pytest_cache' \
        --exclude='dist' \
        --exclude='build' \
        --exclude='.next' \
        --exclude='target' \
        "$CURRENT_DIR/" "$WORKER_PROJECT/"
}

# Copy submodules from source if they exist
copy_submodules() {
    # Copy submodules from source if they exist
    # This avoids needing SSH keys since we're copying from the already-cloned source
    if [ -f "$CURRENT_DIR/.gitmodules" ] && [ -d "$CURRENT_DIR/.git/modules" ]; then
        log_info "Copying submodules from source..."
        
        # Copy .git/modules directory (contains submodule git repositories)
        if ! sudo cp -r "$CURRENT_DIR/.git/modules" "$WORKER_PROJECT/.git/modules" 2>/dev/null; then
            log_warn "Failed to copy submodules - they may not work correctly"
            return 1
        fi
        
        # Fix .git pointers in submodule directories to point to local .git/modules
        # Use git config to properly read submodule paths (more robust than parsing .gitmodules)
        # Use process substitution to avoid subshell issues
        while IFS= read -r line; do
            # Line format: "submodule.<name>.path <path>"
            # Extract path value (everything after the FIRST space, not last)
            # Use read with IFS to split on first space only
            IFS=' ' read -r _ submodule_path <<< "$line"
            # Trim leading/trailing whitespace
            submodule_path="${submodule_path#"${submodule_path%%[![:space:]]*}"}"
            submodule_path="${submodule_path%"${submodule_path##*[![:space:]]}"}"
            
            if [ -n "$submodule_path" ] && [ -d "$WORKER_PROJECT/$submodule_path" ]; then
                # Git stores submodules in .git/modules using the path name
                gitdir_path="$WORKER_PROJECT/.git/modules/$submodule_path"
                if [ -d "$gitdir_path" ]; then
                    # Remove existing .git file or directory
                    sudo rm -rf "$WORKER_PROJECT/$submodule_path/.git" 2>/dev/null || true
                    # Create .git file pointing to .git/modules
                    echo "gitdir: $gitdir_path" | sudo tee "$WORKER_PROJECT/$submodule_path/.git" > /dev/null
                fi
            fi
        done < <(git config --file "$CURRENT_DIR/.gitmodules" --get-regexp '^submodule\..*\.path$' 2>/dev/null || true)
    fi
    return 0
}

# Copy git hooks from source repo to worker
# Hooks are local to each repo and not carried by git clone
copy_git_hooks() {
    local src_hooks="$CURRENT_DIR/.git/hooks"
    local dst_hooks="$WORKER_PROJECT/.git/hooks"

    [ -d "$src_hooks" ] || return 0

    # Find non-sample custom hooks (executable files without .sample extension)
    local found_hooks=false
    for hook in "$src_hooks"/*; do
        [ -f "$hook" ] || continue
        [[ "$hook" == *.sample ]] && continue
        found_hooks=true
        break
    done

    [ "$found_hooks" = true ] || return 0

    log_info "Copying git hooks from source repository..."
    for hook in "$src_hooks"/*; do
        [ -f "$hook" ] || continue
        [[ "$hook" == *.sample ]] && continue
        local hook_name
        hook_name=$(basename "$hook")
        if sudo cp "$hook" "$dst_hooks/$hook_name" 2>/dev/null; then
            sudo chmod +x "$dst_hooks/$hook_name"
            sudo chown "$WORKER_USER:$WORKER_USER" "$dst_hooks/$hook_name"
        else
            log_warn "Failed to copy hook: $hook_name"
        fi
    done
}

# Setup git config for worker user (user.name and user.email)
setup_git_config() {
    # Read git config from the CURRENT directory (host user's repo), not from worker directory
    # This ensures we get the host user's git config, not the worker's
    # Suppress all git errors (including "fatal: failed to stat") to prevent permission issues
    local git_user_name="$(cd "$CURRENT_DIR" 2>/dev/null && git config user.name 2>/dev/null || echo "")"
    local git_user_email="$(cd "$CURRENT_DIR" 2>/dev/null && git config user.email 2>/dev/null || echo "")"

    if [ -n "$git_user_name" ] || [ -n "$git_user_email" ]; then
        # Use git config command to safely set values (avoids injection risk)
        if [ -n "$git_user_name" ]; then
            sudo -u "$WORKER_USER" git -C "$WORKER_HOME" config --file "$WORKER_HOME/.gitconfig" user.name "$git_user_name" 2>/dev/null || true
        fi
        if [ -n "$git_user_email" ]; then
            sudo -u "$WORKER_USER" git -C "$WORKER_HOME" config --file "$WORKER_HOME/.gitconfig" user.email "$git_user_email" 2>/dev/null || true
        fi
    fi
}
