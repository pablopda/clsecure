#!/bin/bash
# lib/sync.sh
# 
# Sync-back logic for importing changes from worker to main repository
# 
# Dependencies: lib/logging.sh, lib/git.sh, lib/worker.sh, lib/vars.sh
# Exports: get_worker_base_commit, detect_worker_changes, import_commits, import_uncommitted_changes, create_branch_and_import, show_sync_summary
# 
# Usage:
#   source lib/sync.sh
#   detect_worker_changes

# Read the base commit recorded at clone time
# Returns empty string if not available (backward compatibility with legacy workers)
get_worker_base_commit() {
    local base_file="$WORKER_HOME/.clsecure/base_commit"
    if sudo test -f "$base_file"; then
        sudo cat "$base_file" 2>/dev/null || echo ""
    else
        echo ""
    fi
}

# Detect changes in worker repository (commits and uncommitted)
# Sets global variables: WORKER_COMMITS, NUM_COMMITS, WORKER_CHANGES
detect_worker_changes() {
    # 1. Check for COMMITS
    # We compare HEAD against the original branch we cloned from.
    # Since we cloned the current dir, 'origin' in the worker points to here.
    # First, fetch to ensure worker's view of origin is up-to-date
    sudo -u "$WORKER_USER" git -C "$WORKER_PROJECT" fetch origin 2>/dev/null || true

    WORKER_COMMITS=$(sudo -u "$WORKER_USER" git -C "$WORKER_PROJECT" log --oneline origin/$ORIGINAL_BRANCH..HEAD 2>/dev/null || echo "")
    # Count commits using grep -c (more accurate than wc -l which counts newlines)
    NUM_COMMITS=$(echo "$WORKER_COMMITS" | grep -c . 2>/dev/null || echo 0)

    # 2. Check for UNCOMMITTED changes
    WORKER_CHANGES=$(sudo -u "$WORKER_USER" bash -c "cd '$WORKER_PROJECT' && git status --porcelain" 2>/dev/null || echo "")
}

# Show summary of detected changes
show_sync_summary() {
    if [ -z "$WORKER_CHANGES" ] && [ "$NUM_COMMITS" -eq 0 ]; then
        log_info "No changes detected (committed or uncommitted)."
        return 0
    fi

    echo "Changes detected:"
    if [ "$NUM_COMMITS" -gt 0 ]; then
        echo -e "${CYAN}$NUM_COMMITS new commit(s):${NC}"
        echo "$WORKER_COMMITS" | head -10
        [ "$NUM_COMMITS" -gt 10 ] && echo "... and more"
    fi

    if [ -n "$WORKER_CHANGES" ]; then
        echo -e "${CYAN}Uncommitted changes:${NC}"
        echo "$WORKER_CHANGES" | head -10
        local change_count=$(echo "$WORKER_CHANGES" | grep -c . 2>/dev/null || echo 0)
        [ "$change_count" -gt 10 ] && echo "... and more"
    fi
    echo ""
    return 1
}

# Import commits from worker repository
import_commits() {
    if [ "$NUM_COMMITS" -eq 0 ]; then
        return 0
    fi

    log_info "Importing $NUM_COMMITS commit(s) from worker..."
    
    # Ensure we can read the worker's git objects
    # We grant read access to others temporarily for the .git directory
    # Store original directory permissions to restore later (only for .git directory itself)
    local old_git_dir_perms=$(stat -c "%a" "$WORKER_PROJECT/.git" 2>/dev/null || echo "")
    sudo chmod -R o+rX "$WORKER_PROJECT/.git"
    
    # Stash any local changes (including untracked files) to avoid merge conflicts
    local stash_created=false
    if ! git diff --quiet || ! git diff --cached --quiet || [ -n "$(git ls-files --others --exclude-standard)" ]; then
        log_info "Stashing local changes (including untracked files)..."
        git stash push -u -m "clsecure: backup before importing worker commits"
        stash_created=true
        log_info "✓ Local changes stashed."
    fi
    
    # Fetch and merge
    # When branching from the recorded base commit, pull is always a fast-forward.
    # Use --ff-only to enforce this. Fall back to --no-rebase --no-edit for legacy workers.
    local pull_flags="--no-rebase --no-edit"
    if [ -n "$(get_worker_base_commit)" ]; then
        pull_flags="--ff-only"
    fi
    if git pull $pull_flags "$WORKER_PROJECT" HEAD; then
        log_info "✓ Commits imported successfully."
        
        # Restore stashed changes if any
        if [ "$stash_created" = true ]; then
            echo ""
            log_info "Restoring stashed changes..."
            if git stash pop; then
                log_info "✓ Stashed changes restored."
            else
                log_warn "Conflicts detected when restoring stashed changes."
                log_warn "Please resolve conflicts manually and run: git stash drop"
            fi
        fi
    else
        log_error "Failed to import commits."
        
        # Restore stash on failure
        if [ "$stash_created" = true ]; then
            log_info "Restoring stashed changes..."
            git stash pop
        fi
        return 1
    fi
    
    # Restore original git permissions for security
    # Restore directory permissions to .git directory itself, then remove world access from contents
    if [ -n "$old_git_dir_perms" ]; then
        # Restore directory permissions to .git itself (not recursive)
        sudo chmod "$old_git_dir_perms" "$WORKER_PROJECT/.git" 2>/dev/null || true
        # Remove world read access from all files and directories inside .git
        # Use find to apply different permissions to files vs directories
        sudo find "$WORKER_PROJECT/.git" -type f -exec chmod o-r {} \; 2>/dev/null || true
        sudo find "$WORKER_PROJECT/.git" -type d -exec chmod o-rX {} \; 2>/dev/null || true
    else
        # Default to removing world read access if we don't know original perms
        # Remove world read from files, world read+execute from directories
        sudo find "$WORKER_PROJECT/.git" -type f -exec chmod o-r {} \; 2>/dev/null || true
        sudo find "$WORKER_PROJECT/.git" -type d -exec chmod o-rX {} \; 2>/dev/null || true
    fi
    
    return 0
}

# Import uncommitted changes from worker repository
import_uncommitted_changes() {
    if [ -z "$WORKER_CHANGES" ]; then
        return 0
    fi

    log_info "Syncing uncommitted changes..."
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
        "$WORKER_PROJECT/" "$CURRENT_DIR/"
    
    sudo chown -R "$(whoami):$(id -gn)" "$CURRENT_DIR"
    
    log_info "✓ Uncommitted changes applied."
    
    echo ""
    git status --short
    echo ""
    
    read -p "Commit these changes now? (y/n): " commit_now
    if [[ "$commit_now" =~ ^[Yy]$ ]]; then
         read -p "Commit message [WIP from Claude]: " commit_msg
         commit_msg=${commit_msg:-"WIP from Claude"}
         git add -A
         git commit -m "$commit_msg"
         log_info "✓ Committed."
    fi
    
    return 0
}

# Create branch and import all work (commits + changes)
create_branch_and_import() {
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local default_branch
    if [ -n "${SESSION_NAME_SANITIZED:-}" ]; then
        default_branch="claude/${SAFE_PROJECT_NAME}-${SESSION_NAME_SANITIZED}-${timestamp}"
    else
        default_branch="claude/${SAFE_PROJECT_NAME}-${timestamp}"
    fi
    
    read -p "Branch name [$default_branch]: " branch_name
    branch_name=${branch_name:-$default_branch}
    
    # Use bash built-in pattern matching instead of echo | grep (more efficient)
    if [[ ! "$branch_name" =~ ^[a-zA-Z0-9/_-]+$ ]]; then
        log_error "Invalid branch name."
        return 1
    fi
    
    if git show-ref --verify --quiet "refs/heads/$branch_name" 2>/dev/null; then
        log_error "Branch already exists."
        return 1
    fi
    
    log_info "Creating branch '$branch_name'..."
    local base_commit
    base_commit=$(get_worker_base_commit)
    if [ -n "$base_commit" ] && git cat-file -e "$base_commit" 2>/dev/null; then
        log_info "Branching from session base (${base_commit:0:8})..."
        git checkout -b "$branch_name" "$base_commit"
    else
        git checkout -b "$branch_name"
    fi
    
    # Import Commits
    if ! import_commits; then
        return 1
    fi
    
    # Sync Uncommitted Changes
    import_uncommitted_changes
    
    # Push / PR logic (simplified from original)
    echo ""
    read -p "Push branch '$branch_name'? (y/n): " push_now
    if [[ "$push_now" =~ ^[Yy]$ ]]; then
        git push -u origin "$branch_name"
    fi
    
    echo ""
    read -p "Switch back to '$ORIGINAL_BRANCH'? (y/n): " switch
    [[ "$switch" =~ ^[Yy]$ ]] && git checkout "$ORIGINAL_BRANCH"
    
    echo ""
    read -p "Remove worker user '$WORKER_USER'? (y/n): " cleanup
    if [[ "$cleanup" =~ ^[Yy]$ ]]; then
        sudo userdel -r "$WORKER_USER" 2>/dev/null || true
        log_info "User removed."
    fi
    
    return 0
}
