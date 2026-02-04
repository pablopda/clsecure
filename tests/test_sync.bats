#!/usr/bin/env bats
# test_sync.bats
#
# Tests for lib/sync.sh — base commit recording and import logic

load test_helpers

# Mock sudo: delegates test, cat, -u, and falls through for other commands
_mock_sudo() {
    sudo() {
        case "$1" in
            test)
                shift
                command test "$@"
                ;;
            cat)
                shift
                command cat "$@"
                ;;
            chmod)
                shift
                command chmod "$@" 2>/dev/null || true
                ;;
            find)
                # no-op for permission restoration
                return 0
                ;;
            stat)
                shift
                command stat "$@"
                ;;
            -u)
                shift  # -u
                shift  # USER
                "$@"
                ;;
            *)
                "$@"
                ;;
        esac
    }
    export -f sudo
}

setup() {
    setup_test
    source_module "vars.sh"
    init_clsecure_vars
    source_module "logging.sh"
    source_module "sync.sh"

    # Set up a real git repo as the "host" project
    export HOST_REPO="$TEST_DIR/host-repo"
    mkdir -p "$HOST_REPO"
    git -C "$HOST_REPO" init -b main
    git -C "$HOST_REPO" config user.email "test@test.com"
    git -C "$HOST_REPO" config user.name "Test"
    echo "initial" > "$HOST_REPO/file.txt"
    git -C "$HOST_REPO" add file.txt
    git -C "$HOST_REPO" commit -m "initial commit"

    # Worker home with .clsecure metadata directory
    export WORKER_HOME="$TEST_DIR/worker-home"
    mkdir -p "$WORKER_HOME/.clsecure"
    export WORKER_USER="test-worker"
    export WORKER_PROJECT="$WORKER_HOME/project"

    _mock_sudo
}

teardown() {
    teardown_test
}

# ---------------------------------------------------------------------------
# Function existence checks
# ---------------------------------------------------------------------------

@test "get_worker_base_commit function exists" {
    assert_function_exists get_worker_base_commit
}

@test "detect_worker_changes function exists" {
    assert_function_exists detect_worker_changes
}

@test "import_commits function exists" {
    assert_function_exists import_commits
}

@test "create_branch_and_import function exists" {
    assert_function_exists create_branch_and_import
}

# ---------------------------------------------------------------------------
# get_worker_base_commit
# ---------------------------------------------------------------------------

@test "get_worker_base_commit returns empty when no file exists" {
    rm -f "$WORKER_HOME/.clsecure/base_commit"
    local result
    result=$(get_worker_base_commit)
    [ -z "$result" ]
}

@test "get_worker_base_commit returns hash when file exists" {
    local expected_hash
    expected_hash=$(git -C "$HOST_REPO" rev-parse HEAD)
    echo "$expected_hash" > "$WORKER_HOME/.clsecure/base_commit"

    local result
    result=$(get_worker_base_commit)
    [ "$result" = "$expected_hash" ]
}

@test "get_worker_base_commit returns empty for missing .clsecure directory" {
    rm -rf "$WORKER_HOME/.clsecure"
    local result
    result=$(get_worker_base_commit)
    [ -z "$result" ]
}

# ---------------------------------------------------------------------------
# Branch creation from base commit
# ---------------------------------------------------------------------------

@test "branch created from base commit when available" {
    # Record the base commit (initial commit)
    local base_commit
    base_commit=$(git -C "$HOST_REPO" rev-parse HEAD)
    echo "$base_commit" > "$WORKER_HOME/.clsecure/base_commit"

    # Advance host HEAD with a new commit (simulates another session's import)
    echo "advanced" > "$HOST_REPO/file2.txt"
    git -C "$HOST_REPO" add file2.txt
    git -C "$HOST_REPO" commit -m "advance HEAD"

    # Now HEAD != base_commit
    local current_head
    current_head=$(git -C "$HOST_REPO" rev-parse HEAD)
    [ "$current_head" != "$base_commit" ]

    # Create a branch from within the host repo
    cd "$HOST_REPO"

    # Simulate create_branch_and_import's branch creation logic
    local bc
    bc=$(get_worker_base_commit)
    [ -n "$bc" ]
    git cat-file -e "$bc"
    git checkout -b "test-branch" "$bc"

    # Verify the branch starts at the base commit, not at the advanced HEAD
    local branch_head
    branch_head=$(git rev-parse HEAD)
    [ "$branch_head" = "$base_commit" ]
}

@test "backward compat: branches from HEAD when no base_commit file" {
    rm -f "$WORKER_HOME/.clsecure/base_commit"

    cd "$HOST_REPO"
    local current_head
    current_head=$(git rev-parse HEAD)

    # Without base commit, get_worker_base_commit returns empty
    local bc
    bc=$(get_worker_base_commit)
    [ -z "$bc" ]

    # Falls back to regular checkout -b (from HEAD)
    git checkout -b "fallback-branch"
    local branch_head
    branch_head=$(git rev-parse HEAD)
    [ "$branch_head" = "$current_head" ]
}

# ---------------------------------------------------------------------------
# Pull fast-forward with base commit
# ---------------------------------------------------------------------------

@test "pull is fast-forward when using base commit" {
    # Record the base commit
    local base_commit
    base_commit=$(git -C "$HOST_REPO" rev-parse HEAD)
    echo "$base_commit" > "$WORKER_HOME/.clsecure/base_commit"

    # Clone to worker (simulates what clsecure does)
    git clone "$HOST_REPO" "$WORKER_PROJECT"
    git -C "$WORKER_PROJECT" config user.email "test@test.com"
    git -C "$WORKER_PROJECT" config user.name "Test"

    # Worker makes commits
    echo "worker change" > "$WORKER_PROJECT/worker.txt"
    git -C "$WORKER_PROJECT" add worker.txt
    git -C "$WORKER_PROJECT" commit -m "worker commit"

    # Host: advance HEAD (simulates another session importing first)
    echo "other session" > "$HOST_REPO/other.txt"
    git -C "$HOST_REPO" add other.txt
    git -C "$HOST_REPO" commit -m "other session import"

    # Now create branch from base_commit in host repo
    cd "$HOST_REPO"
    git checkout -b "import-branch" "$base_commit"

    # Pull from worker with --ff-only should succeed (fast-forward)
    chmod -R o+rX "$WORKER_PROJECT/.git"
    git pull --ff-only "$WORKER_PROJECT" HEAD

    # Verify the worker's commit is on the branch
    git log --oneline | grep -q "worker commit"
}

@test "parallel sessions: second import fast-forwards after first" {
    # Record the base commit
    local base_commit
    base_commit=$(git -C "$HOST_REPO" rev-parse HEAD)

    # Set up two worker clones from the same base
    local worker1="$TEST_DIR/worker1"
    local worker2="$TEST_DIR/worker2"
    git clone "$HOST_REPO" "$worker1"
    git clone "$HOST_REPO" "$worker2"
    git -C "$worker1" config user.email "test@test.com"
    git -C "$worker1" config user.name "Test"
    git -C "$worker2" config user.email "test@test.com"
    git -C "$worker2" config user.name "Test"

    # Worker 1 makes changes
    echo "w1 change" > "$worker1/w1.txt"
    git -C "$worker1" add w1.txt
    git -C "$worker1" commit -m "worker1 commit"

    # Worker 2 makes changes
    echo "w2 change" > "$worker2/w2.txt"
    git -C "$worker2" add w2.txt
    git -C "$worker2" commit -m "worker2 commit"

    cd "$HOST_REPO"

    # Import worker 1: create branch from base, pull
    git checkout -b "session1" "$base_commit"
    chmod -R o+rX "$worker1/.git"
    git pull --ff-only "$worker1" HEAD
    git log --oneline | grep -q "worker1 commit"

    # Merge session1 into main (simulates what user does)
    git checkout main
    git merge session1 --no-edit

    # HEAD has now advanced past base_commit
    local new_head
    new_head=$(git rev-parse HEAD)
    [ "$new_head" != "$base_commit" ]

    # Import worker 2: create branch from base_commit (not HEAD!)
    git checkout -b "session2" "$base_commit"
    chmod -R o+rX "$worker2/.git"

    # This is the key: --ff-only succeeds because branch starts at base_commit
    git pull --ff-only "$worker2" HEAD
    git log --oneline | grep -q "worker2 commit"
}

# ---------------------------------------------------------------------------
# import_commits integration
# ---------------------------------------------------------------------------

@test "import_commits uses ff-only when base commit available" {
    # Record the base commit
    local base_commit
    base_commit=$(git -C "$HOST_REPO" rev-parse HEAD)
    echo "$base_commit" > "$WORKER_HOME/.clsecure/base_commit"

    # Clone to worker
    export WORKER_PROJECT="$TEST_DIR/worker-project"
    git clone "$HOST_REPO" "$WORKER_PROJECT"
    git -C "$WORKER_PROJECT" config user.email "test@test.com"
    git -C "$WORKER_PROJECT" config user.name "Test"

    # Worker makes a commit
    echo "worker" > "$WORKER_PROJECT/worker.txt"
    git -C "$WORKER_PROJECT" add worker.txt
    git -C "$WORKER_PROJECT" commit -m "worker work"

    # Set up host for import
    cd "$HOST_REPO"
    git checkout -b "import-test" "$base_commit"
    export ORIGINAL_BRANCH="main"
    export NUM_COMMITS=1

    # import_commits should succeed with ff-only
    import_commits
    git log --oneline | grep -q "worker work"
}

@test "import_commits uses no-rebase when no base commit (legacy)" {
    rm -f "$WORKER_HOME/.clsecure/base_commit"

    # Clone to worker
    export WORKER_PROJECT="$TEST_DIR/worker-project"
    git clone "$HOST_REPO" "$WORKER_PROJECT"
    git -C "$WORKER_PROJECT" config user.email "test@test.com"
    git -C "$WORKER_PROJECT" config user.name "Test"

    # Worker makes a commit
    echo "worker" > "$WORKER_PROJECT/worker.txt"
    git -C "$WORKER_PROJECT" add worker.txt
    git -C "$WORKER_PROJECT" commit -m "legacy worker work"

    # Set up host for import (from HEAD, legacy style)
    cd "$HOST_REPO"
    git checkout -b "legacy-test"
    export ORIGINAL_BRANCH="main"
    export NUM_COMMITS=1

    # import_commits should succeed with --no-rebase --no-edit
    import_commits
    git log --oneline | grep -q "legacy worker work"
}
