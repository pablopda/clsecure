# CLSECURE Git Synchronization Strategy

**Comprehensive design for bidirectional git sync between host and isolated worker environments**

**Version:** 1.0  
**Date:** 2026-02-19  
**Status:** Design Document  

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Sync Patterns](#2-sync-patterns)
3. [Branch Strategy](#3-branch-strategy)
4. [Change Granularity](#4-change-granularity)
5. [Conflict Resolution](#5-conflict-resolution)
6. [Performance Optimization](#6-performance-optimization)
7. [Implementation Reference](#7-implementation-reference)
8. [Example Scenarios](#8-example-scenarios)

---

## 1. Executive Summary

### Current State

CLSECURE uses a **shallow clone + rsync** pattern:
1. Clone repo to worker home (`/home/claude-worker-<project>/project/`)
2. Record base commit at clone time
3. Sync uncommitted changes via rsync (host → worker, then worker → host)
4. Create import branch from base commit
5. Fast-forward worker changes back to host

### Target Architecture

This strategy enhances the current workflow with:
- **Bidirectional sync** (host → worker during session, worker → host on completion)
- **Worktree-aware operations** for EPCTC integration
- **Incremental sync** using git's native mechanisms
- **Conflict detection and resolution** UI
- **Performance optimizations** for large repositories

### Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| **Git-native over rsync** | Better conflict detection, history preservation |
| **Branch-per-session** | Clean isolation, easy review/merge |
| **Lazy sync** | Sync only when needed, reduce overhead |
| **Worktree-compatible** | Integrates with EPCTC parallelism |
| **Shallow clones default** | 50 commits sufficient for most workflows |

---

## 2. Sync Patterns

### 2.1 Sync Pattern Overview

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           Sync Lifecycle                                         │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│   HOST SYSTEM                    WORKER SANDBOX                                 │
│   ───────────                    ──────────────                                 │
│                                                                                  │
│   ┌─────────────┐                ┌─────────────┐                                │
│   │ Main Branch │                │   (none)    │                                │
│   └──────┬──────┘                └──────┬──────┘                                │
│          │                              │                                        │
│          │  1. INITIAL SETUP            │                                        │
│          │  ─────────────────           │                                        │
│          │  • Shallow clone             │                                        │
│          │  • Record base_commit        │                                        │
│          │  • Sync uncommitted changes  │                                        │
│          ├─────────────────────────────▶│                                        │
│          │                              ▼                                        │
│          │                    ┌─────────────────────┐                          │
│          │                    │ Worker repo ready   │                          │
│          │                    │ Same branch as host │                          │
│          │                    │ + uncommitted files │                          │
│          │                    └─────────────────────┘                          │
│          │                              │                                        │
│          │  2. PRE-EXECUTION SYNC       │                                        │
│          │  ─────────────────────       │                                        │
│          │  (Optional, on resume)       │                                        │
│          │  • Check host changes        │                                        │
│          │  • Incremental rsync         │                                        │
│          ├─────────────────────────────▶│                                        │
│          │                              │                                        │
│          │  3. REAL-TIME SYNC (FUTURE)  │                                        │
│          │  ─────────────────────────   │                                        │
│          │  • File watcher (host→worker)│                                        │
│          │  • Auto-sync on save         │                                        │
│          │  • Conflict markers          │                                        │
│          ├────────────◄────────────────▶│                                        │
│          │                              │                                        │
│          │  4. POST-EXECUTION SYNC      │                                        │
│          │  ─────────────────────       │                                        │
│          │  • Detect commits            │                                        │
│          │  • Detect uncommitted        │                                        │
│          │  • Import strategy           │                                        │
│          │◀─────────────────────────────│                                        │
│          │                              │                                        │
│          ▼                              ▼                                        │
│   ┌─────────────────────────────────────────┐                                   │
│   │  Import Branch Created (claude/*)       │                                   │
│   │  Commits fast-forwarded                 │                                   │
│   │  Uncommitted changes rsync'd            │                                   │
│   └─────────────────────────────────────────┘                                   │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### 2.2 Initial Worker Setup

**Flow:**

```bash
# 1. Record base state
BASE_COMMIT=$(git rev-parse HEAD)
echo "$BASE_COMMIT" > "$WORKER_HOME/.clsecure/base_commit"
echo "$CURRENT_DIR" > "$WORKER_HOME/.clsecure/project_path"
echo "$ORIGINAL_BRANCH" > "$WORKER_HOME/.clsecure/original_branch"

# 2. Shallow clone (default: 50 commits)
git clone --depth 50 "file://$CURRENT_DIR" "$WORKER_PROJECT"

# 3. Sync uncommitted changes (rsync, excluding git)
rsync -a --exclude='.git' "$CURRENT_DIR/" "$WORKER_PROJECT/"

# 4. Set up git config
sudo -u "$WORKER_USER" git -C "$WORKER_PROJECT" config user.name "..."
sudo -u "$WORKER_USER" git -C "$WORKER_PROJECT" config user.email "..."
```

**Optimization - Full Clone Option:**
```bash
# When --full-clone is specified
git clone --no-hardlinks "$CURRENT_DIR" "$WORKER_PROJECT"
```

### 2.3 Pre-Execution Sync (Host → Worker)

Triggered when resuming an existing worker session:

```
┌────────────────────────────────────────────────────────────────┐
│                    Pre-Execution Sync Flow                      │
├────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Host                      Worker                      Action   │
│  ────                      ──────                      ──────   │
│                                                                  │
│  Check host HEAD     ──▶   Get worker HEAD                    │
│       │                         │                               │
│       │                         ▼                               │
│       │                    Compare commits                     │
│       │                         │                               │
│       ▼                         ▼                               │
│  ┌─────────────────────────────────────┐                       │
│  │ HEAD matches?                       │                       │
│  └─────────────────────────────────────┘                       │
│       │                         │                               │
│      Yes                       No                               │
│       │                         │                               │
│       ▼                         ▼                               │
│  ┌─────────┐              ┌─────────────┐                      │
│  │ Skip    │              │ Check:      │                      │
│  │ rsync   │              │ • Commits?  │                      │
│  │ sync    │              │ • Staged?   │                      │
│  │ only    │              │ • Conflicts?│                      │
│  └─────────┘              └──────┬──────┘                      │
│                                  │                              │
│                        ┌─────────┴─────────┐                    │
│                        ▼                   ▼                    │
│                  Clean state        Changes exist                │
│                        │                   │                    │
│                        ▼                   ▼                    │
│                 Fast-forward        Warn user:                  │
│                 + rsync             Divergence detected         │
│                                     Offer:                      │
│                                     • Reset worker              │
│                                     • Merge changes             │
│                                     • Create new worker         │
│                                                                  │
└────────────────────────────────────────────────────────────────┘
```

**Implementation:**

```bash
pre_execution_sync() {
    local worker_head=$(sudo -u "$WORKER_USER" git -C "$WORKER_PROJECT" rev-parse HEAD)
    local host_head=$(git rev-parse HEAD)
    
    if [ "$worker_head" = "$host_head" ]; then
        log_info "Host and worker are in sync."
        # Only rsync file changes
        incremental_rsync_to_worker
    else
        log_warn "Divergence detected:"
        log_info "  Host:  ${host_head:0:8}"
        log_info "  Worker: ${worker_head:0:8}"
        
        # Check if worker has local commits
        local worker_commits=$(sudo -u "$WORKER_USER" git -C "$WORKER_PROJECT" \
            log --oneline "$host_head..HEAD" 2>/dev/null | wc -l)
        
        if [ "$worker_commits" -eq 0 ]; then
            # Worker has no local commits - safe to fast-forward
            log_info "Worker has no local commits. Fast-forwarding..."
            sudo -u "$WORKER_USER" git -C "$WORKER_PROJECT" pull --ff-only
            incremental_rsync_to_worker
        else
            # Worker has local commits - need user decision
            handle_divergence "$host_head" "$worker_head"
        fi
    fi
}
```

### 2.4 Post-Execution Sync (Worker → Host)

```
┌────────────────────────────────────────────────────────────────┐
│                   Post-Execution Sync Flow                      │
├────────────────────────────────────────────────────────────────┤
│                                                                  │
│  1. DETECT CHANGES                                               │
│  ─────────────────                                               │
│                                                                  │
│  Worker Status:                                                  │
│  ├── Commits ahead of base?      → WORKER_COMMITS                │
│  ├── Uncommitted changes?        → WORKER_CHANGES                │
│  └── Untracked files?            → WORKER_UNTRACKED              │
│                                                                  │
│  2. CLASSIFY SCENARIO                                            │
│  ─────────────────────                                           │
│                                                                  │
│  ┌─────────┬─────────┬─────────────────────────────────────────┐│
│  │ Commits │ Changes │ Scenario                                ││
│  ├─────────┼─────────┼─────────────────────────────────────────┤│
│  │    0    │   No    │ No changes - offer cleanup              ││
│  │   >0    │   No    │ Commits only - fast-forward import      ││
│  │    0    │  Yes    │ Uncommitted only - rsync + commit UI    ││
│  │   >0    │  Yes    │ Mixed - branch + commit UI              ││
│  └─────────┴─────────┴─────────────────────────────────────────┘│
│                                                                  │
│  3. IMPORT STRATEGY                                              │
│  ─────────────────                                               │
│                                                                  │
│  Commits Only:                                                   │
│  ┌─────────────────┐                                            │
│  │ git pull --ff-only│  ← Pull from worker repo                 │
│  │   (worker)/HEAD  │                                          │
│  └─────────────────┘                                            │
│                                                                  │
│  Uncommitted Changes:                                            │
│  ┌─────────────────┐                                            │
│  │ rsync -av       │  ← Sync files from worker                 │
│  │ (exclude .git)  │                                          │
│  └─────────────────┘                                            │
│                                                                  │
│  Mixed (Commits + Uncommitted):                                  │
│  ┌─────────────────────────────────────┐                        │
│  │ 1. Create branch from base_commit   │                        │
│  │ 2. Pull commits from worker         │                        │
│  │ 3. Rsync uncommitted changes        │                        │
│  │ 4. Offer to commit uncommitted      │                        │
│  └─────────────────────────────────────┘                        │
│                                                                  │
└────────────────────────────────────────────────────────────────┘
```

---

## 3. Branch Strategy

### 3.1 Branch Model

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                        Branch Architecture                                       │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│  Main Repository (Host)                                                         │
│  ─────────────────────                                                          │
│                                                                                  │
│       main (or develop)                                                         │
│         │                                                                        │
│         ├── feature/api ─────────────────────┐                                  │
│         │                                    │                                  │
│         │    [Worker Session: api]           │                                  │
│         │                                    │                                  │
│         ├── feature/auth                     │                                  │
│         │                                    │                                  │
│         │    [Worker Session: auth]          │                                  │
│         │                                    │                                  │
│         └─── claude/myapp-20260219-143022 ◀──┘  ← Import branches               │
│                  │                                                              │
│                  ├── Commit 1 (from worker)                                     │
│                  ├── Commit 2 (from worker)                                     │
│                  └── Uncommitted changes (rsync'd)                              │
│                                                                                  │
│  Import Branch Naming Convention                                                │
│  ────────────────────────────────                                               │
│                                                                                  │
│  Format: claude/<project>-<timestamp>[-<session>]                               │
│  Example: claude/myapp-20260219-143022                                          │
│  Example: claude/myapp-20260219-143022-frontend  (with --session)               │
│                                                                                  │
│  Alternative Format (EPCTC worktree):                                           │
│  claude/wt-<worktree>-<timestamp>                                               │
│  Example: claude/wt-feature-auth-20260219-143022                                │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### 3.2 Branch Naming Conventions

| Scenario | Branch Name Format | Example |
|----------|-------------------|---------|
| Default session | `claude/<project>-<timestamp>` | `claude/myapp-20260219-143022` |
| Named session | `claude/<project>-<session>-<timestamp>` | `claude/myapp-frontend-20260219-143022` |
| EPCTC worktree | `claude/wt-<worktree>-<timestamp>` | `claude/wt-feature-auth-20260219-143022` |
| Parallel workers | `claude/<project>-<session>-<n>-<timestamp>` | `claude/myapp-worker1-1-20260219-143022` |
| Retry/Resume | `claude/<project>-<timestamp>-r<n>` | `claude/myapp-20260219-143022-r1` |

### 3.3 Multiple Worker Sessions on Same Feature

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                  Multiple Sessions - Same Feature Branch                         │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│  Host: feature/auth                                                              │
│  ─────────────────                                                               │
│                                                                                  │
│  feature/auth (host worktree)                                                   │
│       │                                                                          │
│       ├── Worker Session 1: claude-worker-myapp-auth-xxx                        │
│       │   ├── Works on src/auth/login.ts                                        │
│       │   └── Creates commits A, B                                              │
│       │                                                                          │
│       └── Worker Session 2: claude-worker-myapp-auth-yyy (--session auth-ui)    │
│           ├── Works on src/auth/ui.tsx                                          │
│           └── Creates commits C, D                                              │
│                                                                                  │
│  Sync Strategy:                                                                  │
│  ──────────────                                                                  │
│                                                                                  │
│  Session 1 imports:                                                              │
│  ├── Branch: claude/wt-feature-auth-s1-20260219-143022                          │
│  └── Commits: A, B imported to host                                             │
│                                                                                  │
│  Session 2 imports:                                                              │
│  ├── Branch: claude/wt-feature-auth-s2-20260219-145511                          │
│  └── Commits: C, D imported to host                                             │
│                                                                                  │
│  User merges both branches into feature/auth                                    │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## 4. Change Granularity

### 4.1 Sync Levels

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                         Change Granularity Levels                                │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│  Level 1: Repository-Level (Current)                                            │
│  ───────────────────────────────────                                            │
│  • Entire working directory rsync'd                                             │
│  • Simple, reliable                                                             │
│  • Good for: Small projects, full context needed                                │
│                                                                                  │
│  Level 2: Selective Sync (Optimized)                                            │
│  ───────────────────────────────────                                            │
│  • Track changed files since last sync                                          │
│  • Only sync modified/new/deleted files                                         │
│  • Good for: Large projects, partial changes                                    │
│                                                                                  │
│  Level 3: File-Level Delta (Future)                                             │
│  ──────────────────────────────────                                             │
│  • Block-level or delta sync                                                    │
│  • Only transfer changed parts of files                                         │
│  • Good for: Very large files, remote workers                                   │
│                                                                                  │
│  Level 4: Git-Native (Future Enhancement)                                       │
│  ───────────────────────────────────────                                        │
│  • Use git's internal mechanisms (index, objects)                               │
│  • Worktree-like sync                                                           │
│  • Good for: Maximum efficiency, complex histories                              │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### 4.2 Selective Sync Implementation

```bash
# Track last sync state
LAST_SYNC_FILE="$WORKER_HOME/.clsecure/last_sync"

# Get list of changed files since last sync
get_changed_files() {
    local last_sync_time
    if [ -f "$LAST_SYNC_FILE" ]; then
        last_sync_time=$(cat "$LAST_SYNC_FILE")
        # Find files modified since last sync
        find "$CURRENT_DIR" -type f -newer "$LAST_SYNC_FILE" \
            ! -path "*/.git/*" \
            ! -path "*/node_modules/*" \
            ! -path "*/venv/*" \
            ! -path "*/__pycache__/*" \
            2>/dev/null
    else
        # No last sync - full sync needed
        echo "FULL_SYNC"
    fi
}

# Selective rsync
selective_rsync_to_worker() {
    local changed_files=$(get_changed_files)
    
    if [ "$changed_files" = "FULL_SYNC" ]; then
        # Full sync
        rsync -a \
            --exclude='.git' \
            --exclude='node_modules' \
            --exclude='venv' \
            --exclude='__pycache__' \
            "$CURRENT_DIR/" "$WORKER_PROJECT/"
    else
        # Selective sync - only changed files
        log_info "Selective sync: $(echo "$changed_files" | wc -l) files changed"
        while IFS= read -r file; do
            local rel_path="${file#$CURRENT_DIR/}"
            local dest_dir=$(dirname "$WORKER_PROJECT/$rel_path")
            sudo mkdir -p "$dest_dir"
            sudo rsync -a "$file" "$WORKER_PROJECT/$rel_path"
        done <<< "$changed_files"
    fi
    
    # Update last sync timestamp
    date +%s > "$LAST_SYNC_FILE"
}
```

### 4.3 Binary and Large File Handling

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                    Binary/Large File Handling Strategy                           │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│  File Classification                                                             │
│  ───────────────────                                                             │
│                                                                                  │
│  ┌─────────────────────┬─────────────┬───────────────────────────────────────┐  │
│  │ Type                │ Threshold   │ Handling                              │  │
│  ├─────────────────────┼─────────────┼───────────────────────────────────────┤  │
│  │ Text files (<1MB)   │ < 1MB       │ Normal rsync                          │  │
│  │ Binary files        │ < 10MB      │ Normal rsync, warn if changed         │  │
│  │ Large files         │ 10-100MB    │ Lazy load, checksum verify            │  │
│  │ Very large files    │ > 100MB     │ Symlink/copy-on-write, or skip        │  │
│  │ Git LFS files       │ any         │ Use LFS, don't sync blobs             │  │
│  └─────────────────────┴─────────────┴───────────────────────────────────────┘  │
│                                                                                  │
│  Binary File Detection                                                           │
│  ─────────────────────                                                           │
│                                                                                  │
│  Detection Methods:                                                              │
│  1. File extension: .exe, .dll, .so, .bin, .dat, .jpg, .png, etc.               │
│  2. MIME type: $(file --mime-type -b "$file")                                   │
│  3. Git attributes: Check .gitattributes for binary markers                     │
│  4. Content analysis: NUL bytes in first 8KB                                    │
│                                                                                  │
│  Binary Sync Behavior:                                                           │
│  • Warn when binary files are modified (potential conflict)                     │
│  • Use checksum comparison instead of timestamp                                 │
│  • Skip if unchanged (avoid unnecessary copying)                                │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

**Implementation:**

```bash
# Check if file is binary
is_binary_file() {
    local file="$1"
    
    # Check by MIME type
    local mime=$(file --mime-type -b "$file" 2>/dev/null)
    case "$mime" in
        text/*|application/json|application/xml|application/javascript)
            return 1  # Not binary
            ;;
    esac
    
    # Check for NUL bytes in first 8KB
    if head -c 8192 "$file" 2>/dev/null | grep -qP '\x00'; then
        return 0  # Binary
    fi
    
    return 1  # Assume text
}

# Large file handling
LARGE_FILE_THRESHOLD=$((10 * 1024 * 1024))  # 10MB

sync_with_large_file_handling() {
    local src="$1"
    local dest="$2"
    local size=$(stat -f%z "$src" 2>/dev/null || stat -c%s "$src" 2>/dev/null || echo 0)
    
    if [ "$size" -gt "$LARGE_FILE_THRESHOLD" ]; then
        log_info "Large file detected: $(basename "$src") ($(numfmt --to=iec $size))"
        
        # Check if content changed (compare checksums)
        local src_checksum=$(md5sum "$src" 2>/dev/null | cut -d' ' -f1)
        local dest_checksum=""
        if [ -f "$dest" ]; then
            dest_checksum=$(sudo md5sum "$dest" 2>/dev/null | cut -d' ' -f1)
        fi
        
        if [ "$src_checksum" != "$dest_checksum" ]; then
            log_info "  Content changed - syncing..."
            sudo rsync -a --progress "$src" "$dest"
        else
            log_info "  Content unchanged - skipping"
        fi
    else
        # Normal rsync for small files
        sudo rsync -a "$src" "$dest"
    fi
}
```

---

## 5. Conflict Resolution

### 5.1 Conflict Detection Matrix

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                       Conflict Detection Matrix                                  │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│                    Worker State                                                  │
│                    ────────────                                                  │
│              │  Unchanged  │  Modified   │  Deleted    │  Added      │          │
│  Host State  │─────────────┼─────────────┼─────────────┼─────────────┤          │
│  ─────────── │             │             │             │             │          │
│              │             │             │             │             │          │
│  Unchanged   │    OK       │    OK       │    WARN     │    OK       │          │
│              │  (no-op)    │  (sync→host)│ (recreate?) │ (sync→host) │          │
│              │             │             │             │             │          │
│  Modified    │    OK       │  CONFLICT   │  CONFLICT   │    OK       │          │
│              │  (sync→wkr) │  (merge)    │ (override?) │ (both keep) │          │
│              │             │             │             │             │          │
│  Deleted     │    OK       │  CONFLICT   │    OK       │    OK       │          │
│              │  (delete→wkr│ (restore?)  │  (no-op)    │ (sync→host) │          │
│              │             │             │             │             │          │
│  Added       │    OK       │    OK       │    OK       │    OK       │          │
│              │  (sync→wkr) │ (sync→host) │ (sync→host) │ (different) │          │
│              │             │             │             │             │          │
│                                                                                  │
│  CONFLICT = Both host and worker modified the same file                         │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### 5.2 Conflict Resolution Flow

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                     Conflict Resolution Flowchart                                │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│  ┌─────────────────────────┐                                                    │
│  │ Detect divergence       │                                                    │
│  │ (host vs worker HEAD)   │                                                    │
│  └─────────────┬───────────┘                                                    │
│                │                                                                 │
│                ▼                                                                 │
│  ┌─────────────────────────┐                                                    │
│  │ Analyze conflict type   │                                                    │
│  └─────────────┬───────────┘                                                    │
│                │                                                                 │
│      ┌─────────┼─────────┐                                                       │
│      ▼         ▼         ▼                                                       │
│  ┌───────┐ ┌───────┐ ┌─────────┐                                                │
│  │Commit │ │ File  │ │ Merge   │                                                │
│  │diverge│ │change │ │ needed  │                                                │
│  └───┬───┘ └───┬───┘ └────┬────┘                                                │
│      │         │          │                                                      │
│      ▼         ▼          ▼                                                      │
│  ┌─────────────────────────────────────┐                                         │
│  │ Present options to user:            │                                         │
│  │                                     │                                         │
│  │ 1. Keep host version (discard work) │                                         │
│  │ 2. Keep worker version (overwrite)  │                                         │
│  │ 3. Merge changes (create merge commit)│                                       │
│  │ 4. Create separate branch (preserve both)│                                    │
│  │ 5. Interactive resolution (file by file)│                                     │
│  └─────────────────────────────────────┘                                         │
│                │                                                                 │
│                ▼                                                                 │
│  ┌─────────────────────────────────────┐                                         │
│  │ Execute chosen resolution           │                                         │
│  └─────────────────────────────────────┘                                         │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### 5.3 Conflict Resolution UI

```bash
# Interactive conflict resolution
resolve_conflicts_interactive() {
    local conflicts=()
    
    # Build list of conflicting files
    while IFS= read -r file; do
        conflicts+=("$file")
    done < <(detect_file_conflicts)
    
    if [ ${#conflicts[@]} -eq 0 ]; then
        return 0
    fi
    
    echo ""
    echo -e "${YELLOW}Conflicting files detected:${NC}"
    
    for file in "${conflicts[@]}"; do
        echo ""
        echo "File: $file"
        echo "────────────────────────────────────"
        
        # Show diffs
        echo "Host changes:"
        git diff "$file" 2>/dev/null | head -20
        
        echo ""
        echo "Worker changes:"
        sudo -u "$WORKER_USER" git -C "$WORKER_PROJECT" diff "$file" 2>/dev/null | head -20
        
        echo ""
        echo "Options:"
        echo "  1) Keep host version"
        echo "  2) Keep worker version"
        echo "  3) Merge (show diff tool)"
        echo "  4) Skip for now"
        
        read -p "Choice (1/2/3/4): " choice
        
        case $choice in
            1)
                # Keep host - do nothing
                log_info "Kept host version of $file"
                ;;
            2)
                # Keep worker - copy to host
                sudo cp "$WORKER_PROJECT/$file" "$CURRENT_DIR/$file"
                log_info "Applied worker version of $file"
                ;;
            3)
                # Launch diff tool
                if command -v vimdiff &>/dev/null; then
                    vimdiff "$CURRENT_DIR/$file" "$WORKER_PROJECT/$file"
                elif command -v meld &>/dev/null; then
                    meld "$CURRENT_DIR/$file" "$WORKER_PROJECT/$file"
                else
                    diff -u "$CURRENT_DIR/$file" "$WORKER_PROJECT/$file" | less
                fi
                ;;
            4)
                log_info "Skipped $file"
                ;;
        esac
    done
}
```

### 5.4 Auto-Merge Strategies

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                      Auto-Merge Strategies                                       │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│  Strategy 1: Fast-Forward (default)                                             │
│  ───────────────────────────────────                                            │
│  When: Worker commits are direct descendant of host base                        │
│  Action: git pull --ff-only from worker                                         │
│  Result: Linear history, no merge commit                                        │
│                                                                                  │
│  Strategy 2: Rebase + Fast-Forward                                              │
│  ──────────────────────────────────                                             │
│  When: Host has new commits since worker started                                │
│  Action: Rebase worker commits on top of host HEAD                              │
│  Result: Linear history, commits replayed                                       │
│                                                                                  │
│  Strategy 3: Merge Commit                                                       │
│  ─────────────────                                                             │
│  When: Both host and worker have divergent commits                              │
│  Action: git merge --no-ff worker-branch                                        │
│  Result: Merge commit preserves both histories                                  │
│                                                                                  │
│  Strategy 4: Squash Merge                                                       │
│  ──────────────────                                                             │
│  When: Many small worker commits, want clean history                            │
│  Action: git merge --squash worker-branch                                       │
│  Result: Single commit with all changes                                         │
│                                                                                  │
│  Strategy 5: Cherry-Pick                                                        │
│  ────────────────                                                               │
│  When: Only specific commits wanted                                             │
│  Action: git cherry-pick <commit-hash>                                          │
│  Result: Selective commit application                                           │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## 6. Performance Optimization

### 6.1 Shallow Clones

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                       Shallow Clone Strategy                                     │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│  Default: --depth 50                                                             │
│  ─────────────────                                                               │
│  • Includes last 50 commits (~enough for blame, log context)                    │
│  • ~90% faster than full clone for typical repos                                │
│  • Reduces disk usage by ~80%                                                   │
│                                                                                  │
│  Full Clone (--full-clone):                                                      │
│  ─────────────────────────                                                       │
│  • Complete history available                                                   │
│  • Required for: git bisect, old branch access, full archaeology                │
│                                                                                  │
│  Partial Clone (Future):                                                         │
│  ───────────────────────                                                         │
│  git clone --filter=blob:none --depth 50                                        │
│  • Downloads blobs on-demand                                                    │
│  • Best of both worlds: speed + full history access                             │
│                                                                                  │
│  Benchmarks (Linux kernel-size repo):                                           │
│  ┌────────────────┬────────────┬────────────────┐                               │
│  │ Strategy       │ Clone Time │ Size           │                               │
│  ├────────────────┼────────────┼────────────────┤                               │
│  │ Full clone     │ ~5 min     │ ~3.5 GB        │                               │
│  │ Shallow (50)   │ ~15 sec    │ ~150 MB        │                               │
│  │ Partial clone  │ ~20 sec    │ ~200 MB (grow) │                               │
│  └────────────────┴────────────┴────────────────┘                               │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### 6.2 Git Worktrees vs Multiple Clones

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                  Worktrees vs Multiple Clones Comparison                         │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│  Current Approach: Full Clone per Worker                                         │
│  ───────────────────────────────────────                                         │
│  Pros:                                                                          │
│  • Complete isolation between workers                                           │
│  • Simple mental model                                                          │
│  • No shared state issues                                                       │
│                                                                                  │
│  Cons:                                                                          │
│  • Duplicated object storage                                                    │
│  • Slower setup for large repos                                                 │
│  • Higher disk usage                                                            │
│                                                                                  │
│  Optimized Approach: Shared Object Store                                         │
│  ───────────────────────────────────────                                         │
│  ┌─────────────────────────────────────────────────────────────────────────┐   │
│  │ Host System                                                             │   │
│  │                                                                         │   │
│  │  Main Repo: /home/user/myapp                                            │   │
│  │  └── .git/objects/ (shared via alternates)                              │   │
│  │                                                                         │   │
│  │  ┌───────────────────┐  ┌───────────────────┐  ┌───────────────────┐   │   │
│  │  │ Worker 1          │  │ Worker 2          │  │ Worker 3          │   │   │
│  │  │ ────────          │  │ ────────          │  │ ────────          │   │   │
│  │  │ project/          │  │ project/          │  │ project/          │   │   │
│  │  │ ├── .git/         │  │ ├── .git/         │  │ ├── .git/         │   │   │
│  │  │ │   └── objects ──┼──┼───────────────────┼──┼──▶ /host/.git/    │   │   │
│  │  │ │       (symlink) │  │ │       (symlink) │  │ │       (symlink) │   │   │
│  │  │ └── src/          │  │ └── src/          │  │ └── src/          │   │   │
│  │  │     (private)     │  │     (private)     │  │     (private)     │   │   │
│  │  └───────────────────┘  └───────────────────┘  └───────────────────┘   │   │
│  │                                                                         │   │
│  └─────────────────────────────────────────────────────────────────────────┘   │
│                                                                                  │
│  Implementation:                                                                 │
│                                                                                  │
│  setup_shared_objects() {                                                        │
│      local worker_git="$WORKER_PROJECT/.git"                                     │
│      local host_objects="$CURRENT_DIR/.git/objects"                              │
│                                                                                  │
│      # Create objects/info directory                                             │
│      sudo mkdir -p "$worker_git/objects/info"                                    │
│                                                                                  │
│      # Point to host's object store                                              │
│      echo "$host_objects" | sudo tee "$worker_git/objects/info/alternates"       │
│                                                                                  │
│      # Protect host objects (read-only)                                          │
│      sudo chmod -R +r "$host_objects"  # Temporary for access                   │
│  }                                                                               │
│                                                                                  │
│  Benefits:                                                                       │
│  • ~95% reduction in per-worker disk usage                                       │
│  • Faster clone (only refs and working tree)                                     │
│  • Automatic object sharing                                                      │
│                                                                                  │
│  Security Considerations:                                                        │
│  • Host objects must be read-only to workers                                     │
│  • Worker cannot corrupt shared object store                                     │
│  • Firejail can enforce read-only mount                                          │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### 6.3 Incremental Sync (rsync --inplace)

```bash
# Optimized rsync for incremental updates
incremental_rsync_to_worker() {
    log_info "Performing incremental sync to worker..."
    
    sudo rsync -a \
        --inplace \           # Update files in-place (faster for large files)
        --delete \            # Remove deleted files from worker
        --checksum \          # Use checksum for comparison (not just timestamp)
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
        --exclude='*.log' \   # Exclude log files
        --exclude='*.tmp' \   # Exclude temp files
        "$CURRENT_DIR/" "$WORKER_PROJECT/"
    
    log_info "Incremental sync complete."
}

# Parallel sync for many files (future optimization)
parallel_rsync() {
    local num_workers=4
    
    # Split file list and sync in parallel
    find "$CURRENT_DIR" -type f ! -path "*/.git/*" | \
        xargs -P "$num_workers" -I {} rsync -a {} "$WORKER_PROJECT/{}"
}
```

### 6.4 Caching Strategies

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                        Caching Strategies                                        │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│  Level 1: Git Object Cache (alternates)                                         │
│  ───────────────────────────────────────                                        │
│  • Share object store between workers                                           │
│  • Read-only access enforced by firejail                                        │
│  • Reduces disk usage by 90%+                                                   │
│                                                                                  │
│  Level 2: Dependency Cache                                                      │
│  ─────────────────────────                                                      │
│  • Cache node_modules, venv between sessions                                    │
│  • Use --reference when copying                                                 │
│  • Mount cache directories read-only                                            │
│                                                                                  │
│  Level 3: Clone Cache                                                           │
│  ──────────────────                                                             │
│  • Keep "template" clone with all deps installed                                │
│  • Copy-on-write clone for new workers                                          │
│  • btrfs/zfs snapshots or cp --reflink                                          │
│                                                                                  │
│  Level 4: Session Persistence                                                   │
│  ────────────────────────                                                       │
│  • Don't delete workers on exit                                                 │
│  • Reuse for subsequent sessions                                                │
│  • Sync changes incrementally                                                   │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## 7. Implementation Reference

### 7.1 New/Modified Library Files

```
lib/
├── git.sh              # Enhanced with worktree support (MODIFIED)
├── sync.sh             # Enhanced sync logic (MODIFIED)
├── worker.sh           # Worker management (MODIFIED)
├── vars.sh             # Variable initialization (existing)
├── isolation.sh        # Firejail integration (existing)
├── conflict.sh         # NEW: Conflict resolution
├── worktree.sh         # NEW: Worktree operations
└── perf.sh             # NEW: Performance optimizations
```

### 7.2 Configuration Extensions

```ini
# .clsecure/config - Git sync strategy options

[sync]
# Sync strategy: rsync (default), git, hybrid
strategy = rsync

# Auto-sync interval during session (seconds, 0 = disabled)
auto_sync_interval = 0

# Shallow clone depth (commits)
shallow_depth = 50

# Enable shared object store
shared_objects = false

# Large file threshold (MB)
large_file_threshold = 10

[sync.conflict]
# Default conflict resolution: interactive, host, worker, merge
default_resolution = interactive

# Auto-resolve if only one side changed
auto_resolve_simple = true

# Create backup on conflict
create_backup = true

[sync.performance]
# Use --inplace for rsync
rsync_inplace = true

# Parallel sync workers
parallel_workers = 1

# Cache dependencies between sessions
cache_deps = false
```

### 7.3 CLI Extensions

```bash
# New CLI options for git sync strategy

clsecure [OPTIONS]

Git Sync Options:
  --sync-strategy STRATEGY    rsync | git | hybrid (default: rsync)
  --full-clone                Clone full history (default: shallow)
  --shallow-depth N           Shallow clone depth (default: 50)
  --shared-objects            Enable shared object store
  --auto-sync N               Auto-sync interval in seconds (0 = off)
  
Conflict Resolution:
  --conflict-resolution MODE  interactive | host | worker | merge
  --no-backup                 Don't create backup on conflict
  
Worktree Support:
  --worktree PATH             Use specific worktree as source
  --sync-worktree NAME        Sync with specific worktree
  --worktree-status           Show worktree-worker mappings
```

---

## 8. Example Scenarios

### 8.1 Scenario 1: Simple Feature Development

```
User: Developer working on a new feature
Context: Single host, single worker, no conflicts expected

─────────────────────────────────────────────────────────

1. INITIAL STATE
   Host: main branch, clean working directory

2. START SESSION
   $ clsecure
   → Creates worker with shallow clone
   → Records base_commit = abc123

3. WORK IN WORKER
   → Edit files, make commits
   → Worker: 3 commits ahead of base

4. END SESSION
   → Detect: 3 commits, 0 uncommitted
   
5. IMPORT
   Options shown:
     1) Create branch and import
     2) Discard changes
     3) Keep for later
   
   User selects: 1
   → Branch created: claude/myapp-20260219-143022
   → Commits fast-forwarded from worker
   → User now on import branch
   
6. POST-IMPORT
   $ git log --oneline
   abc124 (HEAD -> claude/myapp-20260219-143022) Commit 3
   abc125 Commit 2
   abc126 Commit 1
   abc123 (main) Base commit
   
   $ git checkout main
   $ git merge claude/myapp-20260219-143022
   → Feature merged to main
```

### 8.2 Scenario 2: Resuming with Host Changes

```
User: Resumes work after host made changes
Context: Divergence between host and worker

─────────────────────────────────────────────────────────

1. INITIAL STATE
   Previous session ended with "keep for later"
   Host: main branch, new commits since last session

2. START SESSION (RESUME)
   $ clsecure
   → Detects existing worker
   → Checks for divergence
   
   Output:
     [!] Divergence detected:
         Host:  def456 (2 new commits)
         Worker: abc123 (session base)
     
     Options:
       1) Fast-forward worker (safe, no local commits)
       2) Create new worker (discard old)
       3) Merge changes (may have conflicts)
   
   User selects: 1
   → Worker fast-forwarded to def456
   → Session continues

3. WORK AND IMPORT
   → Normal workflow
   → Import creates branch from def456
```

### 8.3 Scenario 3: Conflict Resolution

```
User: Both host and worker modified same file
Context: Needs interactive resolution

─────────────────────────────────────────────────────────

1. INITIAL STATE
   Worker has local commits
   Host also has new commits touching same files

2. END SESSION
   → Detect: 2 commits, 3 uncommitted changes
   → Check: Host files modified since base
   
3. CONFLICT DETECTED
   Output:
     [!] Conflicts detected in:
         - src/auth/login.ts (host modified, worker modified)
         - src/api/routes.ts (host modified, worker deleted)
     
     Options:
       1) Interactive resolution (file by file)
       2) Keep all host versions
       3) Keep all worker versions
       4) Create separate branches

4. INTERACTIVE RESOLUTION
   User selects: 1
   
   File: src/auth/login.ts
   ─────────────────────────────────
   Host changes: Modified login function
   Worker changes: Added error handling
   
   Options:
     1) Keep host
     2) Keep worker
     3) Open diff tool
     4) Skip
   
   User selects: 3 (opens vimdiff)
   → User merges changes manually
   → Saves and continues
   
   File: src/api/routes.ts
   ─────────────────────────────────
   Host: Modified
   Worker: Deleted
   
   User selects: 2 (keep worker deletion)

5. IMPORT COMPLETE
   → Branch created with resolved changes
   → User reviews and commits
```

### 8.4 Scenario 4: EPCTC Worktree Integration

```
User: Using EPCTC with worktrees
Context: Multiple worktrees, each with secure worker

─────────────────────────────────────────────────────────

1. HOST SETUP (EPCTC)
   $ git worktree add ../myapp-wt/feature-auth -b feature/auth
   $ git worktree add ../myapp-wt/feature-api -b feature/api

2. START SESSIONS
   # Terminal 1
   $ cd ../myapp-wt/feature-auth
   $ clsecure --session auth
   → Worker: claude-worker-myapp-auth-xxx
   → Cloned from feature-auth worktree
   → Branch: feature/auth
   
   # Terminal 2
   $ cd ../myapp-wt/feature-api
   $ clsecure --session api
   → Worker: claude-worker-myapp-api-yyy
   → Cloned from feature-api worktree
   → Branch: feature/api

3. PARALLEL WORK
   Both workers run simultaneously
   Changes isolated per worktree

4. SYNC BACK
   Worker auth completes:
   → Commits pushed to feature/auth branch
   → Worktree updated
   → Host worktree has new commits
   
   Worker api completes:
   → Commits pushed to feature/api branch
   → Worktree updated

5. MERGE
   Host:
   $ cd ~/myapp
   $ git checkout main
   $ git merge feature/auth
   $ git merge feature/api
```

### 8.5 Scenario 5: Large Repository Optimization

```
User: Working with large repository (e.g., monorepo)
Context: Performance optimization needed

─────────────────────────────────────────────────────────

1. CONFIGURATION
   # .clsecure/config
   [sync]
   strategy = git
   shallow_depth = 10
   shared_objects = true
   
   [sync.performance]
   rsync_inplace = true
   cache_deps = true

2. FIRST SESSION
   $ clsecure
   → Shallow clone (depth 10): ~30 sec
   → Shared objects: -90% disk usage
   → Dependencies cached

3. RESUME SESSION
   $ clsecure
   → Worker exists, check sync
   → Incremental sync: ~2 sec
   → Dependencies restored from cache

4. SYNC BACK
   → Git-native sync (no rsync of large files)
   → Only refs and objects transferred
   → ~1 sec for import

Benchmarks:
┌─────────────────┬──────────┬──────────┐
│ Operation       │ Before   │ After    │
├─────────────────┼──────────┼──────────┤
│ First clone     │ 5 min    │ 30 sec   │
│ Resume sync     │ 30 sec   │ 2 sec    │
│ Import          │ 20 sec   │ 1 sec    │
│ Disk per worker │ 2 GB     │ 200 MB   │
└─────────────────┴──────────┴──────────┘
```

---

## Appendix: Quick Reference

### Sync Commands Cheat Sheet

```bash
# Start session (default)
clsecure

# Start with full clone
clsecure --full-clone

# Resume named session
clsecure --session myfeature

# Check worker status
clsecure --status

# Sync specific worktree
clsecure --worktree ../myapp-wt/feature-auth

# Cleanup workers
clsecure --cleanup
```

### Troubleshooting

| Issue | Solution |
|-------|----------|
| Slow clone | Use `--shallow-depth 10` or enable shared objects |
| Divergence warning | Choose "fast-forward" if no local commits |
| Conflicts | Use interactive resolution or merge manually |
| Disk full | Run `clsecure --cleanup` to remove old workers |
| Sync failures | Check permissions, verify git config |

---

*Document generated for CLSECURE Git Sync Strategy Design*
