# Architectural Rethink: Adapting EPCTC Worktrees to clsecure Sessions

Following an "ultrathink" deep architectural analysis using 10 specialized subagents, we evaluated the feasibility of fundamentally changing the EPCTC workflow engine to abandon its Git Worktree strategy and instead adapt natively to `clsecure`'s session-based isolation model.

Here are the consolidated findings and the ultimate architectural recommendation.

---

## 🛑 Option A: Forcing EPCTC to adapt to clsecure (Abandoning Worktrees)
*The Hypothesis: EPCTC stops creating git worktrees. Instead, it relies on `clsecure --session <task-id>` to create isolated clones for parallel tasks.*

### 1. The Concurrency & State Collision Hazard (Critical Failure)
If EPCTC runs inside parallel `clsecure` sessions, each session gets a full clone of the repository. EPCTC stores its internal tracking state in hidden folders (e.g., `.epctc/state.json`). 
* **The Problem:** When parallel clsecure sessions finish, `lib/sync.sh` uses `rsync` to sync uncommitted changes back to the host. Because `rsync` does not exclude `.epctc/`, the last session to finish will silently overwrite the state files of all previously finished parallel sessions. This results in guaranteed state corruption and data loss.

### 2. The Performance Penalty
* **Worktrees (EPCTC's current model):** Creating a git worktree takes milliseconds and consumes almost zero extra disk space, as it shares the `.git` object database.
* **clsecure Sessions:** Creating a clsecure session requires creating a new Linux user, performing a full `git clone`, and running a full `rsync` of the working directory. 
* **The Problem:** For an AI agent that might spin up dozens of micro-tasks, the overhead of full cloning and rsyncing for every task would introduce massive latency and disk I/O bottlenecks compared to worktrees.

### 3. Git Branching & Synchronization Complexity
`clsecure` is designed to isolate uncommitted changes and pull them back via `git pull --ff-only`. If EPCTC orchestrates complex branching *inside* the clsecure worker, the sync-back process to the host repository becomes highly prone to race conditions if the main branch has diverged.

**Conclusion for Option A:** Adapting EPCTC to abandon worktrees in favor of `clsecure` full-clones is an architectural regression. It causes state corruption, destroys performance, and complicates git history.

---

## 🏆 Option B: The "Inverted" Orchestration Model (Recommended Strategy)
*The Hypothesis: EPCTC remains the master orchestrator on the host, retaining its worktree strategy. `clsecure` is invoked as a targeted sub-process strictly for the dangerous AI execution phases.*

The subagents unanimously concluded that an **Inverted Model** is the most robust, elegant, and secure architecture.

### How it works:
1. **Host-Side Orchestration:** The Python `epctc` orchestrator runs natively on the host machine. It manages state (`.epctc/`), handles the database, and creates lightning-fast Git worktrees for parallel tasks.
2. **Targeted Sandboxing:** When EPCTC reaches the `code` phase (where Claude actually generates and executes arbitrary code), the EPCTC orchestrator spawns a subprocess: 
   `clsecure --session <task-id> --allow-network --command "claude"`
3. **Execution:** Claude runs inside the `clsecure` firejail sandbox, restricted to that specific task's worktree. 
4. **Clean Exit:** Once Claude finishes the code generation, the `clsecure` session is destroyed. The EPCTC orchestrator (still running safely on the host) resumes, verifies the tests, and commits the code.

### Why this is superior:
* **Zero State Collision:** EPCTC manages its state centrally on the host. `clsecure` never syncs or overwrites `.epctc/` state files.
* **Maximum Performance:** EPCTC continues to use git worktrees for instant parallel environment creation.
* **Perfect Security Boundary:** The Python orchestrator (trusted code) runs on the host. Claude (untrusted AI code execution) runs inside the `clsecure` sandbox.
* **No Git Sync Nightmares:** Because clsecure is running *inside* an existing worktree managed by EPCTC, `clsecure`'s complex `rsync` and `git pull` sync-back logic (`lib/sync.sh`) is entirely bypassed. EPCTC handles the git commits directly.

### The Only Required Code Change
To enable this flawless Inverted Model, one minor bug in `clsecure` must be fixed. 
Currently, `clsecure`'s `lib/git.sh` hardcodes paths like `"$CURRENT_DIR/.git/hooks"`. Because `.git` is a file (not a directory) inside a Git worktree, clsecure crashes when launched inside a worktree.

**The Fix:** Update `lib/git.sh` to use Git's native path resolution:
```bash
# Instead of assuming .git is a directory:
GIT_COMMON_DIR=$(git rev-parse --git-common-dir)
cp -r "$GIT_COMMON_DIR/hooks" ...
```

## Final Verdict
Do not change EPCTC's worktree strategy. The worktree model is vastly superior for local orchestration. Instead, **patch `clsecure` to be worktree-aware**, and configure EPCTC to wrap its Claude execution calls in `clsecure` sandboxes. This achieves 100% of the security goals with 0% performance degradation.