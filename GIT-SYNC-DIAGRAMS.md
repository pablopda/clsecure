# CLSECURE Git Sync Strategy - Visual Diagrams

Quick reference diagrams for the git synchronization strategy.

---

## 1. Sync Lifecycle Overview

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           Sync Lifecycle                                         │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│   HOST                          WORKER                           OPERATION      │
│   ────                          ──────                           ─────────      │
│                                                                                  │
│  ┌─────┐                                                          clone         │
│  │.git │────────────────────────────────────┐                    depth=50       │
│  └──┬──┘                                    ▼                                    │
│     │                              ┌─────────────┐                               │
│     │                              │  base_commit│──→ record at start           │
│     │                              └─────────────┘                               │
│     │                                    │                                       │
│     │         rsync (no .git)            │                                       │
│     │────────────────────────────────────▶│                                       │
│     │                                    │                                       │
│     │                              ┌─────▼─────┐                                 │
│     │                              │  Session  │                                 │
│     │                              │  Active   │                                 │
│     │                              └─────┬─────┘                                 │
│     │                                    │                                       │
│     │◀───────────────────────────────────│─── detect changes                     │
│     │     git pull + rsync                    (commits + uncommitted)           │
│     │                                    │                                       │
│  ┌──▼──┐                           ┌─────▼─────┐                                 │
│  │.git │◀─────────────────────────│  Import   │                                 │
│  │ new │   fast-forward           │  Branch   │                                 │
│  │commits                          └───────────┘                                 │
│  └─────┘                            claude/*                                     │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Branch Strategy

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                         Branch Architecture                                      │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│  HOST REPOSITORY                                                                 │
│  ───────────────                                                                 │
│                                                                                  │
│  main                                                                            │
│    │                                                                             │
│    ├── feature/api ──────────────────┐                                           │
│    │                                 │                                           │
│    │   [Worker: api]                 │                                           │
│    │                                 │                                           │
│    ├── feature/auth ────────────────┐│                                           │
│    │                                ││                                           │
│    │   [Worker: auth]               ││                                           │
│    │                                ││                                           │
│    │   claude/app-api-20260219      ││  ← Import branches                        │
│    │   ├── Commit A                 ││                                           │
│    │   └── Commit B                 ││                                           │
│    │                                ││                                           │
│    └─── claude/app-auth-20260219 ◀──┘┘                                           │
│         ├── Commit C                                                             │
│         └── Commit D                                                             │
│                                                                                  │
│  Branch Naming:                                                                  │
│  ─────────────                                                                   │
│  Format: claude/<project>-<timestamp>[-<session>]                               │
│  Example: claude/myapp-20260219-143022                                           │
│  Example: claude/myapp-20260219-143022-frontend  (with --session)               │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Conflict Detection Matrix

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                       Conflict Detection Matrix                                  │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│                        WORKER STATE                                              │
│                   ┌─────────┬─────────┬─────────┬─────────┐                      │
│                   │Unchanged│Modified │Deleted  │Added    │                      │
│              ┌────┼─────────┼─────────┼─────────┼─────────┤                      │
│              │Unch│   OK    │   OK    │  WARN   │   OK    │                      │
│              ├────┼─────────┼─────────┼─────────┼─────────┤                      │
│  HOST STATE  │Mod │   OK    │CONFLICT │CONFLICT │   OK    │                      │
│              ├────┼─────────┼─────────┼─────────┼─────────┤                      │
│              │Del │   OK    │CONFLICT │   OK    │   OK    │                      │
│              ├────┼─────────┼─────────┼─────────┼─────────┤                      │
│              │Add │   OK    │   OK    │   OK    │   OK    │                      │
│              └────┴─────────┴─────────┴─────────┴─────────┘                      │
│                                                                                  │
│  Legend:                                                                         │
│  ───────                                                                         │
│  OK      = No conflict, normal sync                                             │
│  WARN    = Warning (e.g., file deleted on worker, unchanged on host)            │
│  CONFLICT = Both sides changed - requires resolution                            │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## 4. Worktree Integration

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                       Worktree Integration (EPCTC)                               │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│  HOST SYSTEM                                                                     │
│  ───────────                                                                     │
│                                                                                  │
│  ~/myapp (main repo)                                                             │
│  ├── .git/ (main git directory)                                                  │
│  │   └── worktrees/                                                              │
│  │       ├── feature-auth/                                                       │
│  │       └── feature-api/                                                        │
│  └── src/                                                                        │
│                                                                                  │
│  ~/myapp-wt/feature-auth (worktree 1)                                           │
│  ├── .git → ~/myapp/.git/worktrees/feature-auth                                  │
│  └── src/ (branch: feature/auth)                                                 │
│       │                                                                          │
│       │  git clone --depth 50                                                    │
│       ▼                                                                          │
│  ┌──────────────────────┐                                                        │
│  │ Worker: auth         │                                                        │
│  │ project/             │                                                        │
│  │ ├── .git/ (private)  │                                                        │
│  │ └── src/             │                                                        │
│  └──────────────────────┘                                                        │
│                                                                                  │
│  ~/myapp-wt/feature-api (worktree 2)                                            │
│  ├── .git → ~/myapp/.git/worktrees/feature-api                                   │
│  └── src/ (branch: feature/api)                                                  │
│       │                                                                          │
│       │  git clone --depth 50                                                    │
│       ▼                                                                          │
│  ┌──────────────────────┐                                                        │
│  │ Worker: api          │                                                        │
│  │ project/             │                                                        │
│  │ ├── .git/ (private)  │                                                        │
│  │ └── src/             │                                                        │
│  └──────────────────────┘                                                        │
│                                                                                  │
│  Sync: Worker commits → Push to main repo → Worktree updated                     │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## 5. Shared Object Store

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                      Shared Object Store Optimization                            │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│  HOST SYSTEM                                                                     │
│  ───────────                                                                     │
│                                                                                  │
│  ~/myapp                                                                         │
│  └── .git/                                                                       │
│      └── objects/ ◀────────────────────────────────────┐                        │
│          ├── 01/...         (shared read-only)          │                        │
│          ├── ab/...          ▲                          │                        │
│          └── ...             │                          │                        │
│                              │                          │                        │
│          ┌───────────────────┼───────────────────┐      │                        │
│          │                   │                   │      │                        │
│          │  objects/info/alternates              │      │                        │
│          │  ────────────────────────────────     │      │                        │
│          │  /home/user/myapp/.git/objects        │      │                        │
│          │                                       │      │                        │
│  ┌───────▼───────┐    ┌───────────▼───────┐    ┌▼──────┴───────┐               │
│  │ Worker 1      │    │ Worker 2          │    │ Worker 3       │               │
│  │ project/      │    │ project/          │    │ project/       │               │
│  │ ├── .git/     │    │ ├── .git/         │    │ ├── .git/      │               │
│  │ │   └── refs/ │    │ │   └── refs/     │    │ │   └── refs/  │               │
│  │ └── src/      │    │ └── src/          │    │ └── src/       │               │
│  │     (private) │    │     (private)     │    │     (private)  │               │
│  └───────────────┘    └───────────────────┘    └────────────────┘               │
│                                                                                  │
│  Benefits:                                                                       │
│  • Disk usage: 2GB → 200MB per worker (90% reduction)                           │
│  • Clone time: 5min → 30sec (faster - no object copy)                           │
│  • Host objects read-only (security)                                            │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## 6. Performance Comparison

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                     Performance Comparison (Large Repo)                          │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│  Metric                    │ Standard  │ Optimized │ Improvement                 │
│  ──────────────────────────┼───────────┼───────────┼───────────────────────────  │
│  Initial Clone             │ 5 min     │ 30 sec    │ 90% faster                  │
│  Disk per Worker           │ 2 GB      │ 200 MB    │ 90% reduction               │
│  Resume Sync               │ 30 sec    │ 2 sec     │ 93% faster                  │
│  Import Time               │ 20 sec    │ 1 sec     │ 95% faster                  │
│  Memory (active)           │ 500 MB    │ 500 MB    │ same                        │
│                                                                                  │
│  Optimization Techniques:                                                        │
│  ─────────────────────────                                                       │
│                                                                                  │
│  ┌─────────────────────────────────────────────────────────────────────────┐    │
│  │ 1. Shallow Clone (--depth 50 → 10)                                     │    │
│  │    • Only recent history needed                                        │    │
│  │    • 90% faster clone                                                  │    │
│  │                                                                         │    │
│  │ 2. Shared Object Store (git alternates)                                │    │
│  │    • Point to host's objects/                                          │    │
│  │    • No duplication                                                    │    │
│  │                                                                         │    │
│  │ 3. Selective Sync (rsync changed files only)                           │    │
│  │    • Track last_sync timestamp                                         │    │
│  │    • Only sync modified files                                          │    │
│  │                                                                         │    │
│  │ 4. Large File Handling (checksum comparison)                           │    │
│  │    • Skip unchanged large files                                        │    │
│  │    • Show progress for transfers                                       │    │
│  └─────────────────────────────────────────────────────────────────────────┘    │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## 7. Conflict Resolution Flow

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                     Conflict Resolution Flow                                     │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│  ┌─────────────────────────┐                                                     │
│  │ Detect divergence       │                                                     │
│  │ (host vs worker HEAD)   │                                                     │
│  └─────────────┬───────────┘                                                     │
│                │                                                                  │
│                ▼                                                                  │
│  ┌─────────────────────────┐                                                     │
│  │ Worker has commits?     │                                                     │
│  └─────────────┬───────────┘                                                     │
│                │                                                                  │
│         ┌──────┴──────┐                                                          │
│         ▼             ▼                                                          │
│       Yes            No                                                           │
│         │             │                                                           │
│         ▼             ▼                                                           │
│  ┌──────────┐   ┌──────────┐                                                      │
│  │ Diverged │   │ Clean    │                                                      │
│  │ Need     │   │ Fast-    │                                                      │
│  │ merge    │   │ forward  │                                                      │
│  └────┬─────┘   └────┬─────┘                                                      │
│       │              │                                                            │
│       ▼              ▼                                                            │
│  ┌─────────────────────────────────────┐                                          │
│  │ User Options:                       │                                          │
│  │                                     │                                          │
│  │ 1) Fast-forward (if no commits)    │                                          │
│  │ 2) Rebase commits on host HEAD     │                                          │
│  │ 3) Merge (create merge commit)     │                                          │
│  │ 4) Interactive (file by file)      │                                          │
│  │ 5) Create separate branch          │                                          │
│  │ 6) Discard worker, start fresh     │                                          │
│  └─────────────────────────────────────┘                                          │
│       │                                                                           │
│       ▼                                                                           │
│  ┌─────────────────────────────────────┐                                          │
│  │ Execute resolution                  │                                          │
│  │ ├─ Update worker or host            │                                          │
│  │ ├─ Handle file conflicts            │                                          │
│  │ └─ Verify sync successful           │                                          │
│  └─────────────────────────────────────┘                                          │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## 8. Session State Machine

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                      Session State Machine                                       │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│  ┌──────────┐                                                                    │
│  │  IDLE    │◀─────────────────────────────────────────────────────────┐         │
│  └────┬─────┘                                                          │         │
│       │ clsecure                                                       │         │
│       ▼                                                                │         │
│  ┌──────────┐     resume      ┌──────────┐                             │         │
│  │  INIT    │◀────────────────│  PAUSED  │                             │         │
│  └────┬─────┘                 └────┬─────┘                             │         │
│       │ clone/sync                 │                                   │         │
│       ▼                            │ exit (keep)                       │         │
│  ┌──────────┐                      │                                   │         │
│  │  READY   │──────────────────────┘                                   │         │
│  └────┬─────┘                                                                    │
│       │ start session                                                            │
│       ▼                                                                          │
│  ┌──────────┐                                                                    │
│  │ ACTIVE   │◀────────────────┐                                                  │
│  └────┬─────┘                 │                                                  │
│       │ /exit                 │ auto-sync (future)                               │
│       ▼                       │                                                  │
│  ┌──────────┐                 │                                                  │
│  │  SYNC    │─────────────────┘                                                  │
│  └────┬─────┘                                                                    │
│       │                                                                          │
│       ▼                                                                          │
│  ┌─────────────────────────────────────┐                                         │
│  │ Import Decision:                    │                                         │
│  │ ├─ 1) Create branch & import ──▶ IMPORTED                                     │
│  │ ├─ 2) Discard ───────────────▶ CLEANUP ──▶ IDLE                              │
│  │ └─ 3) Keep ──────────────────▶ PAUSED                                         │
│  └─────────────────────────────────────┘                                         │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## Quick Reference

### Sync Commands

```bash
# Start session
clsecure
clsecure --session feature-name

# With optimizations
clsecure --shallow-depth 10 --shared-objects

# Worktree mode
cd ../project-wt/feature-name
clsecure --session feature-name

# Status and cleanup
clsecure --status
clsecure --cleanup
```

### Config Options

```ini
# .clsecure/config
[sync]
strategy = git              # rsync | git | hybrid
shallow_depth = 50          # Clone depth
shared_objects = false      # Enable alternates
auto_sync_interval = 0      # Seconds (0 = off)

[sync.conflict]
default_resolution = interactive  # interactive | host | worker | merge
auto_resolve_simple = true
```
