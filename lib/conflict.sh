#!/bin/bash
# lib/conflict.sh
# 
# Conflict detection and resolution for CLSECURE git sync
# 
# Dependencies: lib/logging.sh, lib/worker.sh, lib/vars.sh
# Exports: detect_divergence, detect_file_conflicts, resolve_conflicts_interactive
#          auto_resolve_conflicts, handle_divergence
# 
# Usage:
#   source lib/conflict.sh
#   detect_divergence

# Detect divergence between host and worker repositories
# Sets: HOST_HEAD, WORKER_HEAD, DIVERGENCE_STATUS, DIVERGENCE_COMMITS
detect_divergence() {
    HOST_HEAD=$(git rev-parse HEAD 2>/dev/null || echo "")
    WORKER_HEAD=$(sudo -u "$WORKER_USER" git -C "$WORKER_PROJECT" rev-parse HEAD 2>/dev/null || echo "")
    
    if [ -z "$HOST_HEAD" ] || [ -z "$WORKER_HEAD" ]; then
        DIVERGENCE_STATUS="error"
        return 1
    fi
    
    if [ "$HOST_HEAD" = "$WORKER_HEAD" ]; then
        DIVERGENCE_STATUS="synced"
        DIVERGENCE_COMMITS=0
        return 0
    fi
    
    # Check if worker is ahead, behind, or diverged
    local ahead=$(sudo -u "$WORKER_USER" git -C "$WORKER_PROJECT" \
        rev-list --count "$HOST_HEAD..HEAD" 2>/dev/null || echo 0)
    local behind=$(sudo -u "$WORKER_USER" git -C "$WORKER_PROJECT" \
        rev-list --count "HEAD..$HOST_HEAD" 2>/dev/null || echo 0)
    
    DIVERGENCE_COMMITS=$((ahead + behind))
    
    if [ "$ahead" -gt 0 ] && [ "$behind" -eq 0 ]; then
        DIVERGENCE_STATUS="worker_ahead"
    elif [ "$ahead" -eq 0 ] && [ "$behind" -gt 0 ]; then
        DIVERGENCE_STATUS="host_ahead"
    else
        DIVERGENCE_STATUS="diverged"
    fi
}

# Detect file-level conflicts between host and worker
# Outputs: List of conflicting file paths
detect_file_conflicts() {
    local tmpdir=$(mktemp -d)
    local host_files="$tmpdir/host"
    local worker_files="$tmpdir/worker"
    local conflicts="$tmpdir/conflicts"
    
    # Get list of modified files on host
    git diff --name-only HEAD 2>/dev/null | sort > "$host_files" || touch "$host_files"
    
    # Get list of modified files in worker
    sudo -u "$WORKER_USER" git -C "$WORKER_PROJECT" diff --name-only HEAD 2>/dev/null | sort > "$worker_files" || touch "$worker_files"
    
    # Find intersection (files modified in both)
    comm -12 "$host_files" "$worker_files" > "$conflicts"
    
    # Also check for cases where host modified and worker deleted (or vice versa)
    local host_deleted=$(git diff --diff-filter=D --name-only HEAD 2>/dev/null | sort)
    local worker_deleted=$(sudo -u "$WORKER_USER" git -C "$WORKER_PROJECT" diff --diff-filter=D --name-only HEAD 2>/dev/null | sort)
    
    # Host deleted, worker modified
    comm -12 <(echo "$host_deleted" | sort) "$worker_files" >> "$conflicts"
    
    # Worker deleted, host modified
    comm -12 "$host_files" <(echo "$worker_deleted" | sort) >> "$conflicts"
    
    # Output unique conflicts
    sort -u "$conflicts"
    
    # Cleanup
    rm -rf "$tmpdir"
}

# Handle divergence with user interaction
handle_divergence() {
    local host_head="${1:-$HOST_HEAD}"
    local worker_head="${2:-$WORKER_HEAD}"
    
    echo ""
    log_warn "Divergence detected between host and worker:"
    echo "  Host HEAD:  ${host_head:0:8}"
    echo "  Worker HEAD: ${worker_head:0:8}"
    echo ""
    
    # Get detailed info
    local worker_commits=$(sudo -u "$WORKER_USER" git -C "$WORKER_PROJECT" \
        log --oneline "$host_head..HEAD" 2>/dev/null | wc -l)
    local host_commits=$(git log --oneline "$worker_head..HEAD" 2>/dev/null | wc -l)
    
    echo "  Worker has $worker_commits commit(s) ahead of host"
    echo "  Host has $host_commits commit(s) ahead of worker"
    echo ""
    
    # Determine available options
    echo "Options:"
    
    if [ "$worker_commits" -eq 0 ]; then
        echo "  1) Fast-forward worker (recommended - no local commits)"
    else
        echo "  1) Merge changes (may have conflicts)"
        echo "  2) Rebase worker commits on host"
        echo "  3) Create separate import branch"
    fi
    
    echo "  4) Create new worker (discard old)"
    echo "  5) Keep as-is (continue with divergence)"
    echo "  6) Abort"
    echo ""
    
    read -p "Choose (1-6): " choice
    
    case $choice in
        1)
            if [ "$worker_commits" -eq 0 ]; then
                fast_forward_worker
            else
                merge_host_into_worker
            fi
            ;;
        2)
            if [ "$worker_commits" -gt 0 ]; then
                rebase_worker_commits
            else
                log_error "Invalid option"
                return 1
            fi
            ;;
        3)
            create_separate_branch
            ;;
        4)
            recreate_worker
            ;;
        5)
            log_info "Continuing with divergence. Changes will be handled on import."
            ;;
        6)
            log_info "Aborted."
            exit 0
            ;;
        *)
            log_error "Invalid option"
            return 1
            ;;
    esac
}

# Fast-forward worker to host HEAD
fast_forward_worker() {
    log_info "Fast-forwarding worker to host HEAD..."
    
    # Fetch from host
    sudo -u "$WORKER_USER" git -C "$WORKER_PROJECT" fetch origin 2>/dev/null || true
    
    # Reset to host HEAD
    if sudo -u "$WORKER_USER" git -C "$WORKER_PROJECT" reset --hard "$HOST_HEAD"; then
        log_info "Worker fast-forwarded successfully."
        # Update base commit
        echo "$HOST_HEAD" | sudo tee "$WORKER_HOME/.clsecure/base_commit" > /dev/null
        return 0
    else
        log_error "Failed to fast-forward worker."
        return 1
    fi
}

# Merge host changes into worker
merge_host_into_worker() {
    log_info "Merging host changes into worker..."
    
    # Add host as remote
    sudo -u "$WORKER_USER" git -C "$WORKER_PROJECT" remote add host "file://$CURRENT_DIR" 2>/dev/null || true
    sudo -u "$WORKER_USER" git -C "$WORKER_PROJECT" fetch host 2>/dev/null || true
    
    # Attempt merge
    if sudo -u "$WORKER_USER" git -C "$WORKER_PROJECT" merge "host/$ORIGINAL_BRANCH" --no-edit; then
        log_info "Merge successful."
        return 0
    else
        log_warn "Merge has conflicts."
        echo "Please resolve conflicts in the worker session."
        return 1
    fi
}

# Rebase worker commits on top of host HEAD
rebase_worker_commits() {
    log_info "Rebasing worker commits on host HEAD..."
    
    # Add host as remote
    sudo -u "$WORKER_USER" git -C "$WORKER_PROJECT" remote add host "file://$CURRENT_DIR" 2>/dev/null || true
    sudo -u "$WORKER_USER" git -C "$WORKER_PROJECT" fetch host 2>/dev/null || true
    
    # Attempt rebase
    if sudo -u "$WORKER_USER" git -C "$WORKER_PROJECT" rebase "host/$ORIGINAL_BRANCH"; then
        log_info "Rebase successful."
        return 0
    else
        log_warn "Rebase has conflicts."
        echo "Please resolve conflicts in the worker session."
        return 1
    fi
}

# Interactive conflict resolution
resolve_conflicts_interactive() {
    local conflicts=()
    
    # Build list of conflicting files
    while IFS= read -r file; do
        [ -n "$file" ] && conflicts+=("$file")
    done < <(detect_file_conflicts)
    
    if [ ${#conflicts[@]} -eq 0 ]; then
        return 0
    fi
    
    echo ""
    log_warn "${#conflicts[@]} conflicting file(s) detected:"
    
    for file in "${conflicts[@]}"; do
        echo ""
        echo -e "${CYAN}File: $file${NC}"
        echo "────────────────────────────────────"
        
        # Check file status in both locations
        local host_status=$(git status --porcelain "$file" 2>/dev/null | cut -c1-2 || echo "  ")
        local worker_status=$(sudo -u "$WORKER_USER" git -C "$WORKER_PROJECT" \
            status --porcelain "$file" 2>/dev/null | cut -c1-2 || echo "  ")
        
        echo "Host status:   '${host_status}'"
        echo "Worker status: '${worker_status}'"
        
        # Show preview of changes
        echo ""
        echo "Host changes (diffstat):"
        git diff --stat "$file" 2>/dev/null | head -5
        
        echo ""
        echo "Worker changes (diffstat):"
        sudo -u "$WORKER_USER" git -C "$WORKER_PROJECT" diff --stat "$file" 2>/dev/null | head -5
        
        echo ""
        echo "Resolution options:"
        echo "  1) Keep host version"
        echo "  2) Keep worker version"
        echo "  3) Show full diff"
        echo "  4) Open diff tool"
        echo "  5) Skip for now"
        
        read -p "Choice (1-5): " choice
        
        case $choice in
            1)
                # Keep host - do nothing
                log_info "Kept host version of $file"
                ;;
            2)
                # Keep worker - copy to host
                local dest_dir=$(dirname "$CURRENT_DIR/$file")
                mkdir -p "$dest_dir"
                sudo cp "$WORKER_PROJECT/$file" "$CURRENT_DIR/$file"
                sudo chown "$(whoami):$(id -gn)" "$CURRENT_DIR/$file"
                log_info "Applied worker version of $file"
                ;;
            3)
                # Show full diff
                echo ""
                echo "Host diff:"
                git diff "$file" 2>/dev/null | head -50
                echo ""
                echo "Worker diff:"
                sudo -u "$WORKER_USER" git -C "$WORKER_PROJECT" diff "$file" 2>/dev/null | head -50
                echo ""
                read -p "Press Enter to continue..."
                ;;
            4)
                # Open diff tool
                local temp_worker=$(mktemp)
                sudo cat "$WORKER_PROJECT/$file" > "$temp_worker" 2>/dev/null || true
                
                if command -v vimdiff &>/dev/null; then
                    vimdiff "$CURRENT_DIR/$file" "$temp_worker"
                    read -p "Apply worker version? (y/n): " apply
                    if [[ "$apply" =~ ^[Yy]$ ]]; then
                        cp "$temp_worker" "$CURRENT_DIR/$file"
                    fi
                elif command -v meld &>/dev/null; then
                    meld "$CURRENT_DIR/$file" "$temp_worker"
                    read -p "Apply worker version? (y/n): " apply
                    if [[ "$apply" =~ ^[Yy]$ ]]; then
                        cp "$temp_worker" "$CURRENT_DIR/$file"
                    fi
                else
                    diff -u "$CURRENT_DIR/$file" "$temp_worker" | less
                fi
                rm -f "$temp_worker"
                ;;
            5)
                log_info "Skipped $file for now"
                ;;
        esac
    done
}

# Auto-resolve simple conflicts (one side unchanged)
auto_resolve_conflicts() {
    local resolution="${1:-interactive}"  # host, worker, interactive
    local resolved=0
    local skipped=0
    
    while IFS= read -r file; do
        [ -z "$file" ] && continue
        
        # Get checksums
        local host_checksum=""
        local worker_checksum=""
        local base_checksum=""
        
        [ -f "$CURRENT_DIR/$file" ] && host_checksum=$(md5sum "$CURRENT_DIR/$file" 2>/dev/null | cut -d' ' -f1)
        [ -f "$WORKER_PROJECT/$file" ] && worker_checksum=$(sudo md5sum "$WORKER_PROJECT/$file" 2>/dev/null | cut -d' ' -f1)
        
        # Check if only one side changed (compare to base)
        local base_file="$WORKER_HOME/.clsecure/base_files/$file"
        if [ -f "$base_file" ]; then
            base_checksum=$(md5sum "$base_file" 2>/dev/null | cut -d' ' -f1)
        fi
        
        # Auto-resolve if possible
        if [ "$host_checksum" = "$base_checksum" ] && [ "$worker_checksum" != "$base_checksum" ]; then
            # Only worker changed - keep worker
            case $resolution in
                worker|interactive)
                    local dest_dir=$(dirname "$CURRENT_DIR/$file")
                    mkdir -p "$dest_dir"
                    sudo cp "$WORKER_PROJECT/$file" "$CURRENT_DIR/$file"
                    sudo chown "$(whoami):$(id -gn)" "$CURRENT_DIR/$file"
                    ((resolved++))
                    ;;
            esac
        elif [ "$worker_checksum" = "$base_checksum" ] && [ "$host_checksum" != "$base_checksum" ]; then
            # Only host changed - keep host
            case $resolution in
                host|interactive)
                    # Already host version, nothing to do
                    ((resolved++))
                    ;;
            esac
        else
            # Both changed - needs manual resolution
            ((skipped++))
        fi
    done < <(detect_file_conflicts)
    
    log_info "Auto-resolved: $resolved, Needs manual: $skipped"
}

# Create a separate import branch when divergence is complex
create_separate_branch() {
    log_info "Creating separate import branch..."
    
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local branch_name="claude/import-$timestamp"
    
    # Create branch from worker HEAD
    git checkout -b "$branch_name" "$WORKER_HEAD"
    
    log_info "Created branch: $branch_name"
    log_info "You can manually merge this branch later."
}

# Recreate worker (discard old)
recreate_worker() {
    log_warn "Removing existing worker and creating fresh clone..."
    
    sudo rm -rf "$WORKER_PROJECT"
    
    # Re-clone
    if clone_repository; then
        sync_working_directory
        log_info "Worker recreated successfully."
        return 0
    else
        log_error "Failed to recreate worker."
        return 1
    fi
}

# Check if file is binary
is_binary_file() {
    local file="$1"
    
    # Check if file exists
    [ -f "$file" ] || return 1
    
    # Check by MIME type
    local mime=$(file --mime-type -b "$file" 2>/dev/null)
    case "$mime" in
        text/*|application/json|application/xml|application/javascript|application/x-shellscript)
            return 1  # Not binary
            ;;
    esac
    
    # Check for NUL bytes in first 8KB
    if head -c 8192 "$file" 2>/dev/null | grep -qP '\x00'; then
        return 0  # Binary
    fi
    
    return 1  # Assume text
}

# Generate sync summary report
generate_sync_report() {
    local report_file="$WORKER_HOME/.clsecure/sync_report.txt"
    
    {
        echo "CLSECURE Sync Report"
        echo "===================="
        echo "Generated: $(date)"
        echo ""
        echo "Host:"
        echo "  Directory: $CURRENT_DIR"
        echo "  Branch: $(git branch --show-current 2>/dev/null || echo 'unknown')"
        echo "  HEAD: $(git rev-parse --short HEAD 2>/dev/null || echo 'unknown')"
        echo ""
        echo "Worker:"
        echo "  User: $WORKER_USER"
        echo "  Directory: $WORKER_PROJECT"
        echo "  Branch: $(sudo -u "$WORKER_USER" git -C "$WORKER_PROJECT" branch --show-current 2>/dev/null || echo 'unknown')"
        echo "  HEAD: $(sudo -u "$WORKER_USER" git -C "$WORKER_PROJECT" rev-parse --short HEAD 2>/dev/null || echo 'unknown')"
        echo ""
        echo "Divergence Status: ${DIVERGENCE_STATUS:-unknown}"
        echo "Commits ahead/behind: ${DIVERGENCE_COMMITS:-0}"
        echo ""
        echo "Conflicting files:"
        detect_file_conflicts | while read -r file; do
            echo "  - $file"
        done
    } | sudo tee "$report_file" > /dev/null
    
    echo "$report_file"
}
