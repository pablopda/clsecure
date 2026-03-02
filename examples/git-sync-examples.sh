#!/bin/bash
# examples/git-sync-examples.sh
#
# Example usage of CLSECURE Git Sync Strategy features
#
# This script demonstrates various scenarios and configurations
# for the enhanced git synchronization capabilities.

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }

# ============================================================================
# Example 1: Basic Usage with Conflict Detection
# ============================================================================
example_basic_with_conflicts() {
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "Example 1: Basic Usage with Conflict Detection"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    
    log_info "Starting clsecure session with conflict detection enabled..."
    log_info ""
    log_info "Commands:"
    log_info "  # Start a session"
    log_info "  clsecure --session feature-auth"
    log_info ""
    log_info "  # The conflict module will automatically:"
    log_info "  1. Detect if host and worker diverge"
    log_info "  2. Offer resolution options if conflicts exist"
    log_info "  3. Provide interactive file-by-file resolution"
    log_info ""
    log_info "  # On exit, if conflicts detected:"
    log_info "  Options:"
    log_info "    1) Interactive resolution"
    log_info "    2) Keep host version"
    log_info "    3) Keep worker version"
    log_info "    4) Create separate branch"
}

# ============================================================================
# Example 2: Worktree-Based Development
# ============================================================================
example_worktree_development() {
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "Example 2: Worktree-Based Development"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    
    log_info "Setting up EPCTC-style worktree workflow..."
    echo ""
    
    log_info "Step 1: Create worktrees on host"
    echo ""
    echo "  # Create worktrees for parallel feature development"
    echo "  git worktree add ../myapp-wt/feature-auth -b feature/auth"
    echo "  git worktree add ../myapp-wt/feature-api -b feature/api"
    echo ""
    
    log_info "Step 2: Start secure sessions for each worktree"
    echo ""
    echo "  # Terminal 1 - Auth feature"
    echo "  cd ../myapp-wt/feature-auth"
    echo "  clsecure --session auth"
    echo ""
    echo "  # Terminal 2 - API feature"
    echo "  cd ../myapp-wt/feature-api"
    echo "  clsecure --session api"
    echo ""
    
    log_info "Step 3: Work in parallel"
    echo ""
    echo "  Each worker is isolated and syncs back to its worktree"
    echo ""
    
    log_info "Step 4: Sync and merge"
    echo ""
    echo "  # After sessions complete, merge worktrees on host"
    echo "  cd ~/myapp"
    echo "  git checkout main"
    echo "  git merge feature/auth"
    echo "  git merge feature/api"
}

# ============================================================================
# Example 3: Performance Optimization for Large Repos
# ============================================================================
example_large_repo_optimization() {
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "Example 3: Performance Optimization for Large Repos"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    
    log_info "Configuration for large repository (e.g., monorepo):"
    echo ""
    
    cat << 'EOF'
# .clsecure/config - Performance optimization settings

[sync]
# Use git-native sync for large repos
strategy = git

# Shallow clone with minimal history
shallow_depth = 10

# Enable shared object store
shared_objects = true

[sync.performance]
# Use inplace updates for faster rsync
rsync_inplace = true

# Cache dependencies between sessions
cache_deps = true

# Large file threshold (MB)
large_file_threshold = 50
EOF
    
    echo ""
    log_info "CLI usage:"
    echo ""
    echo "  # Start with performance optimizations"
    echo "  clsecure --shared-objects --shallow-depth 10"
    echo ""
    echo "  # Check performance report"
    echo "  # (run 'show_perf_report' inside worker)"
    echo ""
    
    log_info "Expected improvements:"
    echo "  • Clone time: 5min → 30sec (90% faster)"
    echo "  • Disk usage: 2GB → 200MB per worker (90% reduction)"
    echo "  • Resume sync: 30sec → 2sec (incremental)"
}

# ============================================================================
# Example 4: Selective Sync for Incremental Updates
# ============================================================================
example_selective_sync() {
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "Example 4: Selective Sync for Incremental Updates"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    
    log_info "Scenario: Resuming work on a large project"
    echo ""
    
    log_info "Initial session:"
    echo ""
    echo "  $ clsecure --session backend"
    echo "  → Full clone (first time)"
    echo "  → Work on feature..."
    echo "  → End session (keep for later)"
    echo ""
    
    log_info "Next day - resume session:"
    echo ""
    echo "  $ clsecure --session backend"
    echo "  → Detects existing worker"
    echo "  → Checks for host changes"
    echo "  → Selective sync: only modified files"
    echo ""
    
    log_info "Behind the scenes:"
    echo ""
    echo "  1. Check last_sync timestamp"
    echo "  2. Find files modified since last sync"
    echo "  3. Rsync only changed files"
    echo "  4. Update last_sync timestamp"
    echo ""
    
    log_info "Benefits:"
    echo "  • Only syncs what's changed"
    echo "  • Much faster for large repos"
    echo "  • Preserves worker state"
}

# ============================================================================
# Example 5: Handling Binary and Large Files
# ============================================================================
example_large_file_handling() {
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "Example 5: Handling Binary and Large Files"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    
    log_info "Configuration for projects with large files:"
    echo ""
    
    cat << 'EOF'
# .clsecure/config - Large file handling

[sync]
# Large file threshold (MB)
large_file_threshold = 25

# Skip certain binary patterns
exclude_patterns = 
    *.psd
    *.mov
    *.dmg
    *.iso

[sync.performance]
# Use checksum for binary comparison
use_checksum = true

# Show progress for large files
show_progress = true
EOF
    
    echo ""
    log_info "Behavior:"
    echo ""
    echo "  Files < 25MB: Normal rsync"
    echo "  Files > 25MB: Checksum comparison first"
    echo "  • If unchanged: Skip (fast)"
    echo "  • If changed: Rsync with progress bar"
    echo ""
    
    log_info "Git LFS integration:"
    echo ""
    echo "  # If using Git LFS, configure to skip LFS objects"
    echo "  # during rsync (they're fetched on demand)"
    echo ""
    echo "  git lfs env  # Check LFS status in worker"
}

# ============================================================================
# Example 6: Multiple Sessions with Auto-Sync
# ============================================================================
example_auto_sync() {
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "Example 6: Multiple Sessions with Auto-Sync"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    
    log_info "Future enhancement: Real-time sync during session"
    echo ""
    
    cat << 'EOF'
# .clsecure/config - Auto-sync settings

[sync]
# Auto-sync interval in seconds (0 = disabled)
auto_sync_interval = 300

# Sync direction: bidirectional, host_to_worker, worker_to_host
auto_sync_direction = host_to_worker

# Conflict handling during auto-sync
auto_sync_on_conflict = warn
EOF
    
    echo ""
    log_info "How it works:"
    echo ""
    echo "  Every 5 minutes (300 seconds):"
    echo "  1. Check for host changes"
    echo "  2. Sync changes to worker"
    echo "  3. Notify if conflicts detected"
    echo ""
    
    log_info "Benefits:"
    echo "  • Worker always has latest host changes"
    echo "  • Reduces divergence issues"
    echo "  • No need to restart session for host updates"
}

# ============================================================================
# Example 7: Complete Workflow Script
# ============================================================================
example_complete_workflow() {
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "Example 7: Complete Workflow Script"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    
    cat << 'EOF'
#!/bin/bash
# complete-workflow.sh - Example complete workflow

PROJECT="myapp"
FEATURE="new-feature"

# Step 1: Start work
#─────────────────────────────
echo "Starting work on $FEATURE..."

# Option A: Simple session
clsecure --session "$FEATURE"

# Option B: Worktree-based (for complex features)
git worktree add "../$PROJECT-wt/$FEATURE" -b "$FEATURE"
cd "../$PROJECT-wt/$FEATURE"
clsecure --session "$FEATURE"

# Step 2: Work in session
#─────────────────────────────
# - Edit files
# - Make commits
# - Test changes
# - Type /exit when done

# Step 3: Handle import
#─────────────────────────────
# On exit, choose:
#   1) Create branch and import
#      → Branch: claude/myapp-feature-20260219-143022
#      → Review changes
#      → Merge to main
#
#   2) Discard changes
#      → Worker removed
#      → Clean slate
#
#   3) Keep for later
#      → Worker preserved
#      → Resume with: clsecure --session "$FEATURE"

# Step 4: Post-import (if worktree)
#─────────────────────────────
cd ~/"$PROJECT"
git checkout main
git merge "$FEATURE"  # Merge feature branch
git worktree remove "../$PROJECT-wt/$FEATURE"

# Step 5: Cleanup
#─────────────────────────────
clsecure --cleanup  # Remove old workers
EOF
}

# ============================================================================
# Example 8: Troubleshooting Common Issues
# ============================================================================
example_troubleshooting() {
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "Example 8: Troubleshooting Common Issues"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    
    log_info "Issue 1: Slow initial clone"
    echo ""
    echo "  Solution:"
    echo "    # Use shallow clone"
    echo "    clsecure --shallow-depth 10"
    echo ""
    echo "    # Or enable shared objects"
    echo "    echo 'shared_objects = true' >> .clsecure/config"
    echo ""
    
    log_info "Issue 2: Divergence warning on resume"
    echo ""
    echo "  Cause: Host has new commits since last session"
    echo ""
    echo "  Solution:"
    echo "    Option 1: Fast-forward worker (if no local commits)"
    echo "    Option 2: Create new worker (discard old)"
    echo "    Option 3: Merge changes manually"
    echo ""
    
    log_info "Issue 3: Permission errors during sync"
    echo ""
    echo "  Cause: File ownership mismatch"
    echo ""
    echo "  Solution:"
    echo "    # Fix ownership after import"
    echo "    sudo chown -R $(whoami):$(id -gn) ."
    echo ""
    
    log_info "Issue 4: Large repo disk usage"
    echo ""
    echo "  Solution:"
    echo "    # Enable shared object store"
    echo "    # Configure in .clsecure/config:"
    echo "    [sync]"
    echo "    shared_objects = true"
    echo "    shallow_depth = 10"
    echo ""
    echo "    # Clean up old workers"
    echo "    clsecure --cleanup"
}

# ============================================================================
# Main menu
# ============================================================================
show_menu() {
    echo ""
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║   CLSECURE Git Sync Strategy Examples                     ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo ""
    echo "Select an example:"
    echo ""
    echo "  1) Basic Usage with Conflict Detection"
    echo "  2) Worktree-Based Development"
    echo "  3) Performance Optimization for Large Repos"
    echo "  4) Selective Sync for Incremental Updates"
    echo "  5) Handling Binary and Large Files"
    echo "  6) Multiple Sessions with Auto-Sync"
    echo "  7) Complete Workflow Script"
    echo "  8) Troubleshooting Common Issues"
    echo ""
    echo "  a) Show all examples"
    echo "  q) Quit"
    echo ""
}

# Main execution
main() {
    if [ $# -eq 0 ]; then
        show_menu
        read -p "Enter choice (1-8, a, q): " choice
    else
        choice="$1"
    fi
    
    case $choice in
        1) example_basic_with_conflicts ;;
        2) example_worktree_development ;;
        3) example_large_repo_optimization ;;
        4) example_selective_sync ;;
        5) example_large_file_handling ;;
        6) example_auto_sync ;;
        7) example_complete_workflow ;;
        8) example_troubleshooting ;;
        a|A)
            example_basic_with_conflicts
            example_worktree_development
            example_large_repo_optimization
            example_selective_sync
            example_large_file_handling
            example_auto_sync
            example_complete_workflow
            example_troubleshooting
            ;;
        q|Q) exit 0 ;;
        *) log_error "Invalid choice"; exit 1 ;;
    esac
    
    echo ""
}

main "$@"
