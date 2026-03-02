#!/bin/bash
# lib/worktree.sh
# 
# Git worktree support for CLSECURE
# Enables integration with EPCTC worktree-based workflows
# 
# Dependencies: lib/logging.sh, lib/worker.sh, lib/git.sh, lib/vars.sh
# Exports: is_git_worktree, detect_worktree_info, clone_worktree_repository
#          sync_back_to_worktree, init_worktree_sync, sync_worker_to_main
#
# Usage:
#   source lib/worktree.sh
#   if is_git_worktree "$CURRENT_DIR"; then
#       clone_worktree_repository
#   fi
#
# KNOWN ISSUES (in dead-code functions, fix before activating):
#   1. sync_worker_to_main():276 — $worktree_path undefined, needs read from
#      $WORKER_HOME/.clsecure/worktree_path (see sync_back_to_worktree for pattern)
#   2. sync_from_other_worktree():322, worktree_pre_execution_sync():481,502 —
#      interactive read prompts without AUTO_SYNC guard, will hang --auto-sync
#   3. worktree_pre_execution_sync():491 — exit 0 kills caller; should be return 0
#   4. sync_back_to_worktree():175 — [ -d "$main_repo_path/.git" ] fails if main
#      repo is itself a worktree; use git rev-parse --git-dir instead
#   5. setup_shared_objects/cleanup_shared_objects — git-common-dir returns relative
#      ".git" for normal repos; use cd+pwd pattern from lib/git.sh if activating
#   6. setup_shared_objects():432 — chmod -R o+r on .git/objects is a security risk
#      if cleanup doesn't run; consider firejail bind-mount instead
#   7. sync_back_to_worktree():159, sync_to_worktree_path():234 — rsync target read
#      from worker-writable file without path validation; sanitize before use

# Check if directory is a git worktree
# Returns 0 if worktree, 1 otherwise
is_git_worktree() {
    local dir="${1:-$CURRENT_DIR}"
    
    # First check: .git is a file (not directory) in worktrees
    if [ -f "$dir/.git" ] && [ ! -d "$dir/.git" ]; then
        return 0
    fi
    
    # Second check: git rev-parse --is-inside-work-tree
    if ! git -C "$dir" rev-parse --is-inside-work-tree &>/dev/null; then
        return 1
    fi
    
    # Third check: git directory contains /worktrees/
    local git_dir=$(git -C "$dir" rev-parse --git-dir 2>/dev/null)
    if [[ "$git_dir" == *"/worktrees/"* ]]; then
        return 0
    fi
    
    return 1
}

# Detect worktree information
# Sets: WORKTREE_IS_WORKTREE, WORKTREE_NAME, WORKTREE_PATH, WORKTREE_BRANCH
#       WORKTREE_MAIN_REPO, WORKTREE_GIT_COMMON_DIR
detect_worktree_info() {
    local dir="${1:-$CURRENT_DIR}"
    
    WORKTREE_IS_WORKTREE=false
    WORKTREE_NAME=""
    WORKTREE_PATH=""
    WORKTREE_BRANCH=""
    WORKTREE_MAIN_REPO=""
    WORKTREE_GIT_COMMON_DIR=""
    
    if ! is_git_worktree "$dir"; then
        return 1
    fi
    
    WORKTREE_IS_WORKTREE=true
    WORKTREE_PATH="$(cd "$dir" && pwd)"
    WORKTREE_NAME=$(basename "$WORKTREE_PATH")
    
    # Get the main git directory
    WORKTREE_GIT_COMMON_DIR=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null)
    
    # Get current branch
    WORKTREE_BRANCH=$(git -C "$dir" branch --show-current 2>/dev/null)
    
    # Find main repo path from git common dir
    # git-common-dir is typically /path/to/repo/.git
    if [ -n "$WORKTREE_GIT_COMMON_DIR" ]; then
        WORKTREE_MAIN_REPO=$(dirname "$WORKTREE_GIT_COMMON_DIR")
    fi
    
    return 0
}

# Clone repository with worktree awareness
# If source is a worktree, clone from worktree and preserve metadata
clone_worktree_repository() {
    if ! is_git_worktree "$CURRENT_DIR"; then
        # Not a worktree - use standard clone
        return 1
    fi
    
    log_info "Detected git worktree - capturing worktree metadata..."
    
    # Detect worktree info
    detect_worktree_info "$CURRENT_DIR"
    
    log_info "  Worktree: $WORKTREE_NAME"
    log_info "  Branch: $WORKTREE_BRANCH"
    log_info "  Main repo: $WORKTREE_MAIN_REPO"
    
    # Store worktree metadata for later sync
    sudo mkdir -p "$WORKER_HOME/.clsecure"
    echo "$WORKTREE_PATH" | sudo tee "$WORKER_HOME/.clsecure/worktree_path" > /dev/null
    echo "$WORKTREE_NAME" | sudo tee "$WORKER_HOME/.clsecure/worktree_name" > /dev/null
    echo "$WORKTREE_BRANCH" | sudo tee "$WORKER_HOME/.clsecure/worktree_branch" > /dev/null
    echo "$WORKTREE_MAIN_REPO" | sudo tee "$WORKER_HOME/.clsecure/worktree_main_repo" > /dev/null
    echo "$WORKTREE_GIT_COMMON_DIR" | sudo tee "$WORKER_HOME/.clsecure/worktree_git_common_dir" > /dev/null
    echo "true" | sudo tee "$WORKER_HOME/.clsecure/is_worktree" > /dev/null
    
    # Clone from the worktree (not main repo) to preserve worktree state
    log_info "Cloning worktree content (branch: $WORKTREE_BRANCH)..."
    [ -n "$WORKER_PROJECT" ] && sudo rm -rf "$WORKER_PROJECT" 2>/dev/null || true
    
    if [ "${FULL_CLONE:-false}" = true ]; then
        if ! sudo git clone --no-hardlinks --quiet "$CURRENT_DIR" "$WORKER_PROJECT"; then
            log_error "Failed to clone worktree repository"
            return 1
        fi
    else
        if ! sudo git clone --quiet --depth 50 "file://$CURRENT_DIR" "$WORKER_PROJECT"; then
            log_error "Failed to clone worktree repository"
            return 1
        fi
    fi
    
    # Checkout the same branch if it exists
    if [ -n "$WORKTREE_BRANCH" ]; then
        sudo -u "$WORKER_USER" git -C "$WORKER_PROJECT" checkout "$WORKTREE_BRANCH" 2>/dev/null || true
    fi
    
    log_info "Worktree cloned successfully."
    return 0
}

# Initialize worktree worker with sync metadata
init_worktree_sync() {
    local worktree_branch="${1:-$WORKTREE_BRANCH}"
    local main_repo_path="${2:-$WORKTREE_MAIN_REPO}"
    
    if [ -z "$worktree_branch" ] || [ -z "$main_repo_path" ]; then
        log_error "Cannot init worktree sync: missing branch or repo path"
        return 1
    fi
    
    # Add main repo as remote "origin" if not already present
    local existing_origin=$(sudo -u "$WORKER_USER" git -C "$WORKER_PROJECT" \
        remote get-url origin 2>/dev/null || echo "")
    
    if [ -z "$existing_origin" ]; then
        sudo -u "$WORKER_USER" git -C "$WORKER_PROJECT" remote add origin "file://$main_repo_path"
        sudo -u "$WORKER_USER" git -C "$WORKER_PROJECT" config remote.origin.fetch \
            "+refs/heads/*:refs/remotes/origin/*"
    fi
    
    # Create/update branch tracking worktree branch
    sudo -u "$WORKER_USER" git -C "$WORKER_PROJECT" checkout -b "$worktree_branch" 2>/dev/null || \
        sudo -u "$WORKER_USER" git -C "$WORKER_PROJECT" checkout "$worktree_branch" 2>/dev/null || true
    
    log_info "Worktree sync initialized for branch: $worktree_branch"
    return 0
}

# Sync changes from worker back to worktree
sync_back_to_worktree() {
    local worktree_path
    worktree_path=$(cat "$WORKER_HOME/.clsecure/worktree_path" 2>/dev/null || echo "")
    
    if [ -z "$worktree_path" ]; then
        log_info "Not a worktree worker - using standard sync"
        return 1
    fi
    
    log_info "Detected worktree origin - syncing to worktree..."
    
    local worktree_branch
    worktree_branch=$(cat "$WORKER_HOME/.clsecure/worktree_branch" 2>/dev/null)
    
    local main_repo_path
    main_repo_path=$(cat "$WORKER_HOME/.clsecure/worktree_main_repo" 2>/dev/null)
    
    # Strategy 1: Git-based sync (recommended)
    # BUG: [ -d ".git" ] fails if main repo is a worktree; use git rev-parse
    if [ -n "$main_repo_path" ] && [ -d "$main_repo_path/.git" ]; then
        log_info "Using git-based sync to main repository..."
        
        # Add main repo as remote if not present
        sudo -u "$WORKER_USER" git -C "$WORKER_PROJECT" remote add worktree_origin \
            "file://$main_repo_path" 2>/dev/null || true
        
        # Fetch to ensure remote is up to date
        sudo -u "$WORKER_USER" git -C "$WORKER_PROJECT" fetch worktree_origin 2>/dev/null || true
        
        # Push changes to main repo
        if sudo -u "$WORKER_USER" git -C "$WORKER_PROJECT" push worktree_origin "HEAD:$worktree_branch"; then
            log_info "Changes pushed to main repo branch: $worktree_branch"
            
            # Update the host worktree (fast-forward if possible)
            if [ -d "$worktree_path" ]; then
                log_info "Updating host worktree..."
                (cd "$worktree_path" && git pull --ff-only 2>/dev/null || \
                    log_warn "Could not auto-update worktree - manual pull needed")
            fi
            
            return 0
        else
            log_warn "Git push failed, falling back to rsync..."
        fi
    fi
    
    # Strategy 2: Direct rsync to worktree
    log_info "Using direct rsync to worktree..."
    
    if [ -d "$worktree_path" ]; then
        # Sync only if worktree path is valid and different from current
        if [ "$worktree_path" != "$CURRENT_DIR" ]; then
            sync_to_worktree_path "$worktree_path"
            return 0
        fi
    fi
    
    return 1
}

# Sync worker files directly to worktree path
sync_to_worktree_path() {
    local worktree_path="$1"
    
    log_info "Syncing uncommitted changes to worktree: $worktree_path"
    
    # Rsync files (not git objects)
    sudo rsync -av \
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
        "$WORKER_PROJECT/" "$worktree_path/"
    
    # Fix ownership
    sudo chown -R "$(whoami):$(id -gn)" "$worktree_path"
    
    log_info "Worktree synced successfully."
    return 0
}

# Push worker changes to main repository
sync_worker_to_main() {
    local worktree_branch
    worktree_branch=$(cat "$WORKER_HOME/.clsecure/worktree_branch" 2>/dev/null)
    
    local main_repo_path
    main_repo_path=$(cat "$WORKER_HOME/.clsecure/worktree_main_repo" 2>/dev/null)
    
    if [ -z "$worktree_branch" ] || [ -z "$main_repo_path" ]; then
        log_error "Not a worktree worker - cannot sync to main"
        return 1
    fi
    
    # Check for commits to push
    local commits_ahead=$(sudo -u "$WORKER_USER" git -C "$WORKER_PROJECT" \
        rev-list --count HEAD ^"$worktree_branch" 2>/dev/null || echo 0)
    
    if [ "$commits_ahead" -eq 0 ]; then
        log_info "No commits to push to main repo"
        return 0
    fi
    
    log_info "Pushing $commits_ahead commit(s) to main repo..."
    
    # Ensure remote is configured
    sudo -u "$WORKER_USER" git -C "$WORKER_PROJECT" remote add origin \
        "file://$main_repo_path" 2>/dev/null || true
    
    # Push to main repo
    if sudo -u "$WORKER_USER" git -C "$WORKER_PROJECT" push origin "HEAD:$worktree_branch"; then
        log_info "Changes pushed to main repo branch: $worktree_branch"
        
        # Update worktree
        # BUG: $worktree_path is undefined here — needs read from
        # $WORKER_HOME/.clsecure/worktree_path (see sync_back_to_worktree)
        if [ -d "$worktree_path" ] && [ "$worktree_path" != "$CURRENT_DIR" ]; then
            (cd "$worktree_path" && git pull --ff-only 2>/dev/null)
        fi
        
        return 0
    else
        log_error "Failed to push to main repo"
        return 1
    fi
}

# Sync changes from another worktree's branch
sync_from_other_worktree() {
    local other_branch="$1"
    
    if [ -z "$other_branch" ]; then
        log_error "No branch specified"
        return 1
    fi
    
    log_info "Fetching changes from branch: $other_branch"
    
    # Fetch from origin
    sudo -u "$WORKER_USER" git -C "$WORKER_PROJECT" fetch origin 2>/dev/null || {
        log_error "Failed to fetch from origin"
        return 1
    }
    
    # Check if branch exists
    if ! sudo -u "$WORKER_USER" git -C "$WORKER_PROJECT" show-ref --verify \
        --quiet "refs/remotes/origin/$other_branch" 2>/dev/null; then
        log_error "Branch '$other_branch' not found on origin"
        return 1
    fi
    
    # Create tracking branch if not exists
    sudo -u "$WORKER_USER" git -C "$WORKER_PROJECT" branch -t "$other_branch" \
        "origin/$other_branch" 2>/dev/null || true
    
    # Show what's available
    echo ""
    echo "Changes available from $other_branch:"
    sudo -u "$WORKER_USER" git -C "$WORKER_PROJECT" log --oneline \
        "HEAD..origin/$other_branch" 2>/dev/null | head -10
    
    echo ""
    # BUG: no AUTO_SYNC guard — this will hang in --auto-sync mode
    read -p "Merge changes from $other_branch? (y/n): " merge_choice
    if [[ "$merge_choice" =~ ^[Yy]$ ]]; then
        if sudo -u "$WORKER_USER" git -C "$WORKER_PROJECT" merge "origin/$other_branch" --no-edit; then
            log_info "Merged changes from $other_branch"
            return 0
        else
            log_warn "Merge has conflicts - please resolve manually"
            return 1
        fi
    fi
    
    return 0
}

# List all worktree workers for current project
list_worktree_workers() {
    local project_hash="$PROJECT_HASH"
    
    echo ""
    echo -e "${GREEN}Worktree Workers:${NC}"
    echo ""
    
    local found=0
    while IFS=: read -r username _ _ _ _ home_dir _; do
        if [[ "$username" == claude-worker-* ]]; then
            # Check if this worker belongs to current project
            if [ -f "$home_dir/.clsecure/is_worktree" ]; then
                local worker_hash=$(echo "$username" | grep -oE '[a-f0-9]{6}$' || echo "")
                if [ "$worker_hash" = "$project_hash" ] || [ -z "$project_hash" ]; then
                    local worktree_name=$(cat "$home_dir/.clsecure/worktree_name" 2>/dev/null || echo "unknown")
                    local worktree_branch=$(cat "$home_dir/.clsecure/worktree_branch" 2>/dev/null || echo "unknown")
                    local session=$(cat "$home_dir/.clsecure/session_name" 2>/dev/null || echo "default")
                    
                    printf "  %-25s %-15s %-20s %s\n" "$username" "$session" "$worktree_name" "$worktree_branch"
                    ((found++))
                fi
            fi
        fi
    done < /etc/passwd
    
    if [ $found -eq 0 ]; then
        echo "  No worktree workers found for this project."
    fi
    
    echo ""
}

# Show worktree status for a worker
show_worktree_status() {
    echo ""
    echo -e "${GREEN}Worktree Status:${NC}"
    echo ""
    
    local is_worktree=$(cat "$WORKER_HOME/.clsecure/is_worktree" 2>/dev/null || echo "false")
    
    if [ "$is_worktree" != "true" ]; then
        echo "  This is not a worktree worker."
        echo ""
        return
    fi
    
    local worktree_path=$(cat "$WORKER_HOME/.clsecure/worktree_path" 2>/dev/null || echo "unknown")
    local worktree_name=$(cat "$WORKER_HOME/.clsecure/worktree_name" 2>/dev/null || echo "unknown")
    local worktree_branch=$(cat "$WORKER_HOME/.clsecure/worktree_branch" 2>/dev/null || echo "unknown")
    local main_repo=$(cat "$WORKER_HOME/.clsecure/worktree_main_repo" 2>/dev/null || echo "unknown")
    
    echo "  Worktree Information:"
    echo "    Path:    $worktree_path"
    echo "    Name:    $worktree_name"
    echo "    Branch:  $worktree_branch"
    echo "    Main:    $main_repo"
    echo ""
    
    # Show commit status
    echo "  Sync Status:"
    local worker_head=$(sudo -u "$WORKER_USER" git -C "$WORKER_PROJECT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
    echo "    Worker HEAD: $worker_head"
    
    if [ -d "$worktree_path" ]; then
        local worktree_head=$(cd "$worktree_path" && git rev-parse --short HEAD 2>/dev/null || echo "unknown")
        echo "    Worktree HEAD: $worktree_head"
        
        if [ "$worker_head" = "$worktree_head" ]; then
            echo -e "    ${GREEN}Status: In sync${NC}"
        else
            echo -e "    ${YELLOW}Status: Diverged${NC}"
        fi
    fi
    
    echo ""
}

# Setup shared object store for worktree workers
# NOTE: git-common-dir returns relative ".git" for normal repos — if activating
# this function, use cd+pwd pattern from lib/git.sh to ensure absolute path
setup_shared_objects() {
    local main_repo_objects
    main_repo_objects="$(git -C "$CURRENT_DIR" rev-parse --git-common-dir 2>/dev/null)/objects"
    
    # Check if host objects exist
    if [ ! -d "$main_repo_objects" ]; then
        log_error "Cannot setup shared objects: host objects directory not found"
        return 1
    fi
    
    # Create objects/info directory in worker
    sudo mkdir -p "$WORKER_PROJECT/.git/objects/info"
    
    # Point to host's object store via alternates
    echo "$main_repo_objects" | sudo tee "$WORKER_PROJECT/.git/objects/info/alternates" > /dev/null
    
    # Set permissions on host objects to allow read access
    # This is done temporarily - should be restricted by firejail
    sudo chmod -R o+r "$main_repo_objects" 2>/dev/null || true
    
    log_info "Shared object store configured"
    log_info "  Host objects: $main_repo_objects"
    log_info "  Worker: $WORKER_PROJECT"
    
    return 0
}

# Cleanup shared object access (call on exit)
cleanup_shared_objects() {
    local main_repo_objects
    main_repo_objects="$(git -C "$CURRENT_DIR" rev-parse --git-common-dir 2>/dev/null)/objects"
    
    # Remove world read access from host objects
    if [ -d "$main_repo_objects" ]; then
        sudo find "$main_repo_objects" -type f -exec chmod o-r {} \; 2>/dev/null || true
        sudo find "$main_repo_objects" -type d -exec chmod o-rX {} \; 2>/dev/null || true
    fi
}

# Enhanced worktree-aware pre-execution sync
worktree_pre_execution_sync() {
    if ! is_git_worktree "$CURRENT_DIR"; then
        # Not a worktree - use standard sync
        return 1
    fi
    
    log_info "Worktree detected - performing worktree-aware sync..."
    
    # Get worktree info
    detect_worktree_info "$CURRENT_DIR"
    
    # Check if worker exists
    if [ ! -d "$WORKER_PROJECT" ]; then
        log_info "Worker doesn't exist - needs initial setup"
        return 1
    fi
    
    # Check if worker knows about this worktree
    local worker_is_worktree=$(cat "$WORKER_HOME/.clsecure/is_worktree" 2>/dev/null || echo "false")
    if [ "$worker_is_worktree" != "true" ]; then
        log_warn "Existing worker is not a worktree worker"
        echo "Options:"
        echo "  1) Replace with worktree-aware worker"
        echo "  2) Continue with standard sync"
        echo "  3) Abort"
        
        # BUG: no AUTO_SYNC guard — this will hang in --auto-sync mode
        read -p "Choice (1/2/3): " choice
        case $choice in
            1)
                sudo rm -rf "$WORKER_PROJECT"
                return 1  # Signal to re-clone
                ;;
            2)
                return 1  # Use standard sync
                ;;
            3)
                exit 0  # BUG: should be 'return 0' — exit kills caller
                ;;
        esac
    fi
    
    # Check for divergence
    local worker_branch=$(cat "$WORKER_HOME/.clsecure/worktree_branch" 2>/dev/null)
    
    if [ "$worker_branch" != "$WORKTREE_BRANCH" ]; then
        log_warn "Branch mismatch:"
        log_warn "  Worker branch: $worker_branch"
        log_warn "  Worktree branch: $WORKTREE_BRANCH"
        
        read -p "Switch worker to current branch? (y/n): " switch
        if [[ "$switch" =~ ^[Yy]$ ]]; then
            sudo -u "$WORKER_USER" git -C "$WORKER_PROJECT" checkout "$WORKTREE_BRANCH" 2>/dev/null || {
                log_warn "Could not checkout branch - creating..."
                sudo -u "$WORKER_USER" git -C "$WORKER_PROJECT" checkout -b "$WORKTREE_BRANCH"
            }
            echo "$WORKTREE_BRANCH" | sudo tee "$WORKER_HOME/.clsecure/worktree_branch" > /dev/null
        fi
    fi
    
    # Perform standard divergence check
    return 1  # Signal to continue with standard divergence handling
}
