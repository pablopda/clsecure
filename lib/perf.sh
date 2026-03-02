#!/bin/bash
# lib/perf.sh
# 
# Performance optimizations for CLSECURE git sync
# 
# Dependencies: lib/logging.sh, lib/worker.sh, lib/vars.sh
# Exports: check_repo_size, get_optimal_clone_depth, selective_rsync_to_worker
#          incremental_rsync_to_worker, sync_with_large_file_handling
#          is_binary_file, cache_dependencies, setup_git_alternates
# 
# Usage:
#   source lib/perf.sh
#   check_repo_size
#   selective_rsync_to_worker

# Repository size thresholds (in MB)
SMALL_REPO_THRESHOLD=50      # < 50MB = small
MEDIUM_REPO_THRESHOLD=200    # 50-200MB = medium
LARGE_REPO_THRESHOLD=1000    # 200MB-1GB = large
VERY_LARGE_REPO_THRESHOLD=5000  # > 5GB = very large

# Check repository size and characteristics
check_repo_size() {
    local repo_dir="${1:-$CURRENT_DIR}"
    
    # Get .git directory size
    local git_size=0
    local git_dir
    git_dir=$(git -C "$repo_dir" rev-parse --git-common-dir 2>/dev/null)
    if [ -n "$git_dir" ] && [ -d "$git_dir" ]; then
        git_size=$(sudo du -sm "$git_dir" 2>/dev/null | cut -f1 || echo 0)
    fi
    
    # Get working directory size (excluding .git)
    local work_size=0
    work_size=$(sudo du -sm --exclude=".git" "$repo_dir" 2>/dev/null | cut -f1 || echo 0)
    
    # Get file counts
    local total_files=$(find "$repo_dir" -type f ! -path "*/.git/*" 2>/dev/null | wc -l)
    local binary_files=$(find_binary_files "$repo_dir" | wc -l)
    
    # Classify repository
    local size_class="small"
    if [ "$git_size" -gt "$VERY_LARGE_REPO_THRESHOLD" ]; then
        size_class="very_large"
    elif [ "$git_size" -gt "$LARGE_REPO_THRESHOLD" ]; then
        size_class="large"
    elif [ "$git_size" -gt "$MEDIUM_REPO_THRESHOLD" ]; then
        size_class="medium"
    fi
    
    # Output results
    echo "size_class=$size_class"
    echo "git_size_mb=$git_size"
    echo "work_size_mb=$work_size"
    echo "total_files=$total_files"
    echo "binary_files=$binary_files"
    
    return 0
}

# Get optimal clone depth based on repo characteristics
get_optimal_clone_depth() {
    local repo_dir="${1:-$CURRENT_DIR}"
    
    # Parse size info
    local size_info=$(check_repo_size "$repo_dir")
    local git_size=$(echo "$size_info" | grep "git_size_mb=" | cut -d= -f2)
    local total_files=$(echo "$size_info" | grep "total_files=" | cut -d= -f2)
    
    # Determine optimal depth
    local depth=50  # default
    
    if [ "$git_size" -gt "$LARGE_REPO_THRESHOLD" ]; then
        # Very large repo - shallow clone
        depth=10
    elif [ "$git_size" -gt "$MEDIUM_REPO_THRESHOLD" ]; then
        # Large repo - moderate depth
        depth=25
    elif [ "$total_files" -gt 10000 ]; then
        # Many files - reduce depth for faster checkout
        depth=30
    fi
    
    # Respect FULL_CLONE setting
    if [ "${FULL_CLONE:-false}" = true ]; then
        echo "full"
    else
        echo "$depth"
    fi
}

# Find binary files in repository
find_binary_files() {
    local repo_dir="${1:-$CURRENT_DIR}"
    
    find "$repo_dir" -type f ! -path "*/.git/*" ! -path "*/node_modules/*" 2>/dev/null | while read -r file; do
        if is_binary_file "$file"; then
            echo "$file"
        fi
    done
}

# Check if file is binary
is_binary_file() {
    local file="$1"
    
    # Check if file exists
    [ -f "$file" ] || return 1
    
    # Quick check by extension
    case "$file" in
        *.exe|*.dll|*.so|*.dylib|*.bin|*.dat|*.db|*.sqlite|*.jpg|*.jpeg|*.png|*.gif|*.ico|*.pdf|*.zip|*.tar|*.gz|*.bz2|*.xz|*.7z|*.rar|*.woff|*.woff2|*.ttf|*.otf|*.eot)
            return 0
            ;;
    esac
    
    # Check by MIME type
    local mime=$(file --mime-type -b "$file" 2>/dev/null)
    case "$mime" in
        text/*|application/json|application/xml|application/javascript|application/x-shellscript|application/x-python-code)
            return 1  # Not binary
            ;;
        image/*|video/*|audio/*|application/octet-stream|application/x-executable|application/x-sharedlib|application/x-archive|application/zip|application/gzip|application/x-font*)
            return 0  # Binary
            ;;
    esac
    
    # Check for NUL bytes in first 8KB
    if head -c 8192 "$file" 2>/dev/null | grep -qP '\x00'; then
        return 0  # Binary
    fi
    
    return 1  # Assume text
}

# Selective rsync - only changed files
selective_rsync_to_worker() {
    local last_sync_file="$WORKER_HOME/.clsecure/last_sync"
    local use_checksum="${1:-false}"
    
    log_info "Performing selective sync..."
    
    # Build rsync options
    local rsync_opts="-a"
    
    if [ "$use_checksum" = true ]; then
        rsync_opts="$rsync_opts --checksum"
    fi
    
    # Standard excludes
    local exclude_opts=""
    local excludes=('.git' 'node_modules' 'venv' '.venv' '__pycache__' '.pytest_cache' 'dist' 'build' '.next' 'target' '*.log' '*.tmp')
    
    for ex in "${excludes[@]}"; do
        exclude_opts="$exclude_opts --exclude='$ex'"
    done
    
    # Check if we have last sync info
    if [ -f "$last_sync_file" ]; then
        local last_sync_time=$(cat "$last_sync_file")
        log_info "Last sync: $(date -d "@$last_sync_time" 2>/dev/null || echo 'unknown')"
        
        # Find files modified since last sync
        local changed_files=$(find "$CURRENT_DIR" -type f -newer "$last_sync_file" \
            ! -path "*/.git/*" \
            ! -path "*/node_modules/*" \
            ! -path "*/venv/*" \
            ! -path "*/__pycache__/*" 2>/dev/null)
        
        local file_count=$(echo "$changed_files" | grep -c . 2>/dev/null || echo 0)
        
        if [ "$file_count" -eq 0 ]; then
            log_info "No changed files detected"
            return 0
        fi
        
        log_info "Syncing $file_count changed file(s)..."
        
        # Sync only changed files
        while IFS= read -r file; do
            [ -z "$file" ] && continue
            
            local rel_path="${file#$CURRENT_DIR/}"
            local dest_dir=$(dirname "$WORKER_PROJECT/$rel_path")
            
            sudo mkdir -p "$dest_dir"
            
            # Use large file handling for big files
            local file_size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null || echo 0)
            if [ "$file_size" -gt $((10 * 1024 * 1024)) ]; then
                sync_with_large_file_handling "$file" "$WORKER_PROJECT/$rel_path"
            else
                sudo rsync -a "$file" "$WORKER_PROJECT/$rel_path"
            fi
        done <<< "$changed_files"
    else
        # No last sync - do full sync
        log_info "No previous sync detected - performing full sync"
        full_rsync_to_worker
    fi
    
    # Update last sync timestamp
    date +%s | sudo tee "$last_sync_file" > /dev/null
    
    return 0
}

# Incremental rsync with --inplace optimization
incremental_rsync_to_worker() {
    log_info "Performing incremental sync with optimizations..."
    
    sudo rsync -a \
        --inplace \
        --delete \
        --checksum \
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
        --exclude='*.log' \
        --exclude='*.tmp' \
        --exclude='.DS_Store' \
        --exclude='Thumbs.db' \
        "$CURRENT_DIR/" "$WORKER_PROJECT/"
    
    log_info "Incremental sync complete"
    return 0
}

# Full rsync (standard behavior)
full_rsync_to_worker() {
    log_info "Performing full rsync..."
    
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
    
    return 0
}

# Sync with large file handling
LARGE_FILE_THRESHOLD=$((10 * 1024 * 1024))  # 10MB

sync_with_large_file_handling() {
    local src="$1"
    local dest="$2"
    
    local file_size=$(stat -f%z "$src" 2>/dev/null || stat -c%s "$src" 2>/dev/null || echo 0)
    local filename=$(basename "$src")
    
    if [ "$file_size" -gt "$LARGE_FILE_THRESHOLD" ]; then
        log_info "Large file: $filename ($(numfmt --to=iec $file_size))"
        
        # Check if destination exists and compare checksums
        if [ -f "$dest" ]; then
            local src_checksum=$(md5sum "$src" 2>/dev/null | cut -d' ' -f1)
            local dest_checksum=$(sudo md5sum "$dest" 2>/dev/null | cut -d' ' -f1)
            
            if [ "$src_checksum" = "$dest_checksum" ]; then
                log_info "  Unchanged - skipping"
                return 0
            else
                log_info "  Changed - syncing with progress..."
                sudo rsync -a --progress "$src" "$dest"
                return 0
            fi
        else
            log_info "  New file - syncing with progress..."
            sudo rsync -a --progress "$src" "$dest"
            return 0
        fi
    else
        # Normal rsync for small files
        sudo rsync -a "$src" "$dest"
        return 0
    fi
}

# Setup git alternates for shared object store
# NOTE: git-common-dir returns relative ".git" for normal repos — if activating
# this function, use cd+pwd pattern from lib/git.sh to ensure absolute path
setup_git_alternates() {
    local host_objects
    host_objects="$(git -C "$CURRENT_DIR" rev-parse --git-common-dir 2>/dev/null)/objects"
    
    if [ ! -d "$host_objects" ]; then
        log_error "Host objects directory not found"
        return 1
    fi
    
    # Create objects/info directory
    sudo mkdir -p "$WORKER_PROJECT/.git/objects/info"
    
    # Write alternates file
    echo "$host_objects" | sudo tee "$WORKER_PROJECT/.git/objects/info/alternates" > /dev/null
    
    # Verify
    if [ -f "$WORKER_PROJECT/.git/objects/info/alternates" ]; then
        log_info "Git alternates configured"
        log_info "  Host objects: $host_objects"
        return 0
    else
        log_error "Failed to configure git alternates"
        return 1
    fi
}

# Cache dependencies between sessions
cache_dependencies() {
    local cache_dir="$WORKER_HOME/.clsecure/cache"
    
    # Create cache directories
    sudo mkdir -p "$cache_dir/node_modules"
    sudo mkdir -p "$cache_dir/venv"
    
    log_info "Dependency cache ready at $cache_dir"
}

# Restore dependencies from cache
restore_cached_dependencies() {
    local cache_dir="$WORKER_HOME/.clsecure/cache"
    
    if [ ! -d "$cache_dir" ]; then
        return 1
    fi
    
    # Restore node_modules if cache exists and project doesn't have them
    if [ -d "$cache_dir/node_modules" ] && [ ! -d "$WORKER_PROJECT/node_modules" ]; then
        if [ -f "$WORKER_PROJECT/package.json" ]; then
            log_info "Restoring node_modules from cache..."
            sudo cp -r "$cache_dir/node_modules" "$WORKER_PROJECT/"
            sudo chown -R "$WORKER_USER:$WORKER_USER" "$WORKER_PROJECT/node_modules"
        fi
    fi
    
    # Restore venv if cache exists
    if [ -d "$cache_dir/venv" ] && [ ! -d "$WORKER_PROJECT/venv" ]; then
        if [ -f "$WORKER_PROJECT/requirements.txt" ] || [ -f "$WORKER_PROJECT/pyproject.toml" ]; then
            log_info "Restoring venv from cache..."
            sudo cp -r "$cache_dir/venv" "$WORKER_PROJECT/"
            sudo chown -R "$WORKER_USER:$WORKER_USER" "$WORKER_PROJECT/venv"
        fi
    fi
}

# Save dependencies to cache
save_dependencies_to_cache() {
    local cache_dir="$WORKER_HOME/.clsecure/cache"
    
    if [ -d "$WORKER_PROJECT/node_modules" ]; then
        log_info "Caching node_modules..."
        sudo rm -rf "$cache_dir/node_modules"
        sudo cp -r "$WORKER_PROJECT/node_modules" "$cache_dir/"
    fi
    
    if [ -d "$WORKER_PROJECT/venv" ]; then
        log_info "Caching venv..."
        sudo rm -rf "$cache_dir/venv"
        sudo cp -r "$WORKER_PROJECT/venv" "$cache_dir/"
    fi
}

# Parallel rsync for many files (experimental)
parallel_rsync() {
    local src="$1"
    local dest="$2"
    local num_workers="${3:-4}"
    
    log_info "Performing parallel rsync with $num_workers workers..."
    
    # Get list of files
    local file_list=$(find "$src" -type f ! -path "*/.git/*" 2>/dev/null)
    
    # Split and sync in parallel
    echo "$file_list" | xargs -P "$num_workers" -I {} bash -c '
        rel_path="${1#$2}"
        dest_file="$3/$rel_path"
        mkdir -p "$(dirname "$dest_file")"
        rsync -a "$1" "$dest_file"
    ' _ {} "$src" "$dest"
    
    return 0
}

# Estimate sync time based on repo size
estimate_sync_time() {
    local size_info=$(check_repo_size)
    local work_size=$(echo "$size_info" | grep "work_size_mb=" | cut -d= -f2)
    local total_files=$(echo "$size_info" | grep "total_files=" | cut -d= -f2)
    
    # Rough estimates (seconds)
    local base_time=2
    local size_time=$((work_size / 50))  # ~50MB/sec
    local files_time=$((total_files / 1000))  # ~1000 files/sec
    
    local total_time=$((base_time + size_time + files_time))
    
    if [ "$total_time" -lt 5 ]; then
        echo "< 5 seconds"
    elif [ "$total_time" -lt 60 ]; then
        echo "~${total_time} seconds"
    else
        echo "~$((total_time / 60)) minutes"
    fi
}

# Show performance report
show_perf_report() {
    echo ""
    echo -e "${GREEN}Performance Report:${NC}"
    echo ""
    
    local size_info=$(check_repo_size)
    
    echo "Repository:"
    echo "  Size class: $(echo "$size_info" | grep "size_class=" | cut -d= -f2)"
    echo "  Git size: $(echo "$size_info" | grep "git_size_mb=" | cut -d= -f2) MB"
    echo "  Working size: $(echo "$size_info" | grep "work_size_mb=" | cut -d= -f2) MB"
    echo "  Total files: $(echo "$size_info" | grep "total_files=" | cut -d= -f2)"
    echo "  Binary files: $(echo "$size_info" | grep "binary_files=" | cut -d= -f2)"
    echo ""
    
    echo "Sync performance:"
    echo "  Estimated full sync time: $(estimate_sync_time)"
    echo "  Optimal clone depth: $(get_optimal_clone_depth)"
    echo ""
    
    echo "Optimization recommendations:"
    local git_size=$(echo "$size_info" | grep "git_size_mb=" | cut -d= -f2)
    
    if [ "$git_size" -gt "$LARGE_REPO_THRESHOLD" ]; then
        echo "  • Use --shallow-depth 10 for faster clones"
        echo "  • Enable shared_objects in config"
        echo "  • Consider using git worktrees for parallel work"
    elif [ "$git_size" -gt "$MEDIUM_REPO_THRESHOLD" ]; then
        echo "  • Use default shallow clone (depth 50)"
        echo "  • Consider selective sync for resuming"
    else
        echo "  • Repository is small - full clone is fine"
    fi
    
    echo ""
}
