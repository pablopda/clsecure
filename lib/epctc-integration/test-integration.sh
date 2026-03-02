#!/bin/bash
# lib/epctc-integration/test-integration.sh
#
# Test integration module for clsecure × EPCTC
# Provides isolated test execution, result synchronization, and quality gates
#
# Dependencies: lib/logging.sh, lib/sync.sh, lib/vars.sh
# Usage: source lib/epctc-integration/test-integration.sh

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

DEFAULT_TEST_CONFIG=".clsecure/epctc-test-config"
TEST_RESULTS_DIR=".clsecure/test-results"
EPCTC_GATES_DIR=".epctc/gates"

# -----------------------------------------------------------------------------
# Test Risk Profile Detection
# -----------------------------------------------------------------------------

# Detect risk profile for a given test pattern
detect_test_risk_profile() {
    local test_pattern="${1:-}"
    local config_file="${2:-$DEFAULT_TEST_CONFIG}"
    
    # Default to safe tier
    local profile="tier_1"
    
    # Load configuration if exists
    if [ -f "$config_file" ]; then
        # Check each tier's patterns
        for tier in tier_4 tier_3 tier_2 tier_1; do
            local patterns=$(grep "^${tier}_patterns" "$config_file" | cut -d= -f2 | tr -d ' "')
            
            for pattern in $(echo "$patterns" | tr ',' ' '); do
                if [[ "$test_pattern" == $pattern ]]; then
                    profile="$tier"
                    break 2
                fi
            done
        done
    fi
    
    # Heuristic detection if no config match
    if [ "$profile" = "tier_1" ]; then
        case "$test_pattern" in
            *e2e*|*puppeteer*|*cypress*|*playwright*|*selenium*)
                profile="tier_3"
                ;;
            *integration*|*api*|*http*)
                profile="tier_2"
                ;;
            *security*|*fuzz*|*property*|*mutation*)
                profile="tier_4"
                ;;
            *)
                profile="tier_1"
                ;;
        esac
    fi
    
    echo "$profile"
}

# Get isolation configuration for a risk profile
get_isolation_for_profile() {
    local profile="$1"
    local config_file="${2:-$DEFAULT_TEST_CONFIG}"
    
    # Default configuration
    local mode="namespace"
    local network="false"
    local docker="false"
    local readonly="false"
    
    # Parse from config file if exists
    if [ -f "$config_file" ]; then
        mode=$(grep "^${profile}_isolation" "$config_file" | cut -d= -f2 | tr -d ' "' || echo "namespace")
        network=$(grep "^${profile}_network" "$config_file" | cut -d= -f2 | tr -d ' "' || echo "false")
        docker=$(grep "^${profile}_docker" "$config_file" | cut -d= -f2 | tr -d ' "' || echo "false")
        readonly=$(grep "^${profile}_readonly" "$config_file" | cut -d= -f2 | tr -d ' "' || echo "false")
    fi
    
    # Output as JSON
    jq -n \
        --arg mode "$mode" \
        --argjson network "$(convert_to_json_bool "$network")" \
        --argjson docker "$(convert_to_json_bool "$docker")" \
        --argjson readonly "$(convert_to_json_bool "$readonly")" \
        '{mode: $mode, network: $network, docker: $docker, readonly: $readonly}'
}

# Helper: Convert string to JSON boolean
convert_to_json_bool() {
    local val="$1"
    if [ "$val" = "true" ] || [ "$val" = "yes" ] || [ "$val" = "1" ]; then
        echo "true"
    else
        echo "false"
    fi
}

# -----------------------------------------------------------------------------
# Test Session Management
# -----------------------------------------------------------------------------

# Generate unique test session name
generate_test_session_name() {
    local test_type="${1:-test}"
    local timestamp=$(date +%s)
    local random_suffix=$(printf '%04x' $((RANDOM % 65536)))
    echo "epctc-${test_type}-${timestamp}-${random_suffix}"
}

# Initialize test session manifest
init_test_session() {
    local session_name="$1"
    local test_type="$2"
    local test_pattern="$3"
    local isolation_config="$4"
    
    local results_dir="$CURRENT_DIR/$TEST_RESULTS_DIR/$session_name"
    mkdir -p "$results_dir"
    
    # Parse isolation config
    local mode=$(echo "$isolation_config" | jq -r '.mode')
    local network=$(echo "$isolation_config" | jq -r '.network')
    local docker=$(echo "$isolation_config" | jq -r '.docker')
    
    # Create manifest
    cat > "$results_dir/manifest.json" <<EOF
{
    "session_name": "$session_name",
    "test_type": "$test_type",
    "test_pattern": "$test_pattern",
    "isolation": {
        "mode": "$mode",
        "network": $network,
        "docker": $docker
    },
    "started_at": "$(date -Iseconds)",
    "status": "initialized",
    "worker_user": "",
    "exit_code": null
}
EOF
    
    echo "$results_dir"
}

# Update test session status
update_test_session() {
    local session_name="$1"
    local status="$2"
    local exit_code="${3:-null}"
    
    local manifest="$CURRENT_DIR/$TEST_RESULTS_DIR/$session_name/manifest.json"
    
    if [ -f "$manifest" ]; then
        local tmp_file="${manifest}.tmp"
        jq --arg status "$status" \
           --argjson exit_code "${exit_code:-null}" \
           --arg completed_at "$(date -Iseconds)" \
           '.status = $status | .exit_code = $exit_code | .completed_at = $completed_at' \
           "$manifest" > "$tmp_file" && mv "$tmp_file" "$manifest"
    fi
}

# -----------------------------------------------------------------------------
# Test Result Synchronization
# -----------------------------------------------------------------------------

# Sync test results from worker to host
sync_test_results() {
    local session_name="${1:-$SESSION_NAME}"
    local worker_project="${2:-$WORKER_PROJECT}"
    
    local host_results_dir="$CURRENT_DIR/$TEST_RESULTS_DIR/$session_name"
    local worker_results_dir="$worker_project/$TEST_RESULTS_DIR/$session_name"
    
    log_info "Syncing test results from worker..."
    
    # Ensure host directory exists
    mkdir -p "$host_results_dir"
    
    # Check if worker has results
    if ! sudo test -d "$worker_results_dir" 2>/dev/null; then
        log_warn "No results directory found in worker"
        return 1
    fi
    
    # Sync using rsync (preserve structure)
    sudo rsync -av \
        --exclude='node_modules' \
        --exclude='.git' \
        --exclude='__pycache__' \
        --exclude='*.pyc' \
        "$worker_results_dir/" "$host_results_dir/" 2>/dev/null || true
    
    # Fix permissions
    sudo chown -R "$(whoami):$(id -gn)" "$host_results_dir" 2>/dev/null || true
    
    # Also sync common test output locations
    local worker_test_dirs=(
        "$worker_project/junit.xml"
        "$worker_project/test-results"
        "$worker_project/coverage"
        "$worker_project/htmlcov"
        "$worker_project/.coverage"
        "$worker_project/coverage.xml"
    )
    
    for test_dir in "${worker_test_dirs[@]}"; do
        if sudo test -e "$test_dir" 2>/dev/null; then
            local basename=$(basename "$test_dir")
            sudo rsync -av "$test_dir" "$host_results_dir/$basename" 2>/dev/null || true
            sudo chown -R "$(whoami):$(id -gn)" "$host_results_dir/$basename" 2>/dev/null || true
        fi
    done
    
    # Generate summary
    generate_test_summary "$host_results_dir"
    
    log_info "✓ Test results synced to: $host_results_dir"
}

# Generate test summary from results
generate_test_summary() {
    local results_dir="$1"
    local summary_file="$results_dir/summary.json"
    
    local test_count=0
    local failure_count=0
    local error_count=0
    local skipped_count=0
    local duration=0
    
    # Parse JUnit XML if available
    local junit_file=""
    for f in "$results_dir/junit.xml" "$results_dir/TEST-*.xml" "$results_dir"/*.xml; do
        [ -f "$f" ] && { junit_file="$f"; break; }
    done
    
    if [ -n "$junit_file" ] && [ -f "$junit_file" ]; then
        # Extract test counts from JUnit XML
        test_count=$(grep -o 'tests="[0-9]*"' "$junit_file" | head -1 | grep -o '[0-9]*' || echo "0")
        failure_count=$(grep -o 'failures="[0-9]*"' "$junit_file" | head -1 | grep -o '[0-9]*' || echo "0")
        error_count=$(grep -o 'errors="[0-9]*"' "$junit_file" | head -1 | grep -o '[0-9]*' || echo "0")
        skipped_count=$(grep -o 'skipped="[0-9]*"' "$junit_file" | head -1 | grep -o '[0-9]*' || echo "0")
        duration=$(grep -o 'time="[0-9.]*"' "$junit_file" | head -1 | grep -o '[0-9.]*' || echo "0")
    fi
    
    # Calculate coverage if available
    local coverage_pct=null
    if [ -f "$results_dir/coverage/index.html" ]; then
        coverage_pct=$(grep -o 'pc_cov">[0-9]*%' "$results_dir/coverage/index.html" | grep -o '[0-9]*' | head -1 || echo "null")
    elif [ -f "$results_dir/coverage.xml" ]; then
        coverage_pct=$(grep -o 'line-rate="[0-9.]*"' "$results_dir/coverage.xml" | head -1 | grep -o '[0-9.]*' | awk '{print int($1 * 100)}' || echo "null")
    fi
    
    # Create summary JSON
    jq -n \
        --argjson tests "${test_count:-0}" \
        --argjson failures "${failure_count:-0}" \
        --argjson errors "${error_count:-0}" \
        --argjson skipped "${skipped_count:-0}" \
        --argjson duration "${duration:-0}" \
        --argjson coverage "${coverage_pct:-null}" \
        '{
            tests: $tests,
            failures: $failures,
            errors: $errors,
            skipped: $skipped,
            duration: $duration,
            coverage: $coverage,
            passed: ($failures == 0 and $errors == 0),
            generated_at: now | todate
        }' > "$summary_file"
    
    # Display summary
    log_info "Test Summary:"
    log_info "  Tests: $test_count"
    log_info "  Failures: $failure_count"
    log_info "  Errors: $error_count"
    log_info "  Skipped: $skipped_count"
    [ -n "$coverage_pct" ] && log_info "  Coverage: ${coverage_pct}%"
}

# -----------------------------------------------------------------------------
# Quality Gate Integration
# -----------------------------------------------------------------------------

# Check test quality gates
check_test_quality_gates() {
    local results_dir="$1"
    local gates_config="${2:-$CURRENT_DIR/$EPCTC_GATES_DIR/test-gates.json}"
    
    log_info "Checking test quality gates..."
    
    if [ ! -f "$gates_config" ]; then
        log_info "No quality gates configured, skipping"
        return 0
    fi
    
    local summary_file="$results_dir/summary.json"
    if [ ! -f "$summary_file" ]; then
        log_warn "No test summary found, skipping gate checks"
        return 0
    fi
    
    local all_passed=true
    local violations=()
    
    # Load summary
    local summary=$(cat "$summary_file")
    
    # Check coverage gate
    local coverage_threshold=$(jq -r '.gates["test-coverage"].threshold // empty' "$gates_config")
    if [ -n "$coverage_threshold" ]; then
        local coverage=$(echo "$summary" | jq -r '.coverage // 0')
        if [ "$coverage" != "null" ] && [ "$coverage" -lt "$coverage_threshold" ]; then
            violations+=("Coverage: ${coverage}% < ${coverage_threshold}% threshold")
            all_passed=false
        fi
    fi
    
    # Check test count gate
    local min_tests=$(jq -r '.gates["min-tests"].count // empty' "$gates_config")
    if [ -n "$min_tests" ]; then
        local test_count=$(echo "$summary" | jq -r '.tests // 0')
        if [ "$test_count" -lt "$min_tests" ]; then
            violations+=("Test count: ${test_count} < ${min_tests} minimum")
            all_passed=false
        fi
    fi
    
    # Report results
    if [ "$all_passed" = true ]; then
        log_info "✓ All test quality gates passed"
        return 0
    else
        log_error "✗ Test quality gates failed:"
        for violation in "${violations[@]}"; do
            log_error "  - $violation"
        done
        return 1
    fi
}

# Update EPCTC gate file with test results
update_epctc_gate() {
    local session_name="$1"
    local gate_type="${2:-test}"
    
    local gate_file="$CURRENT_DIR/$EPCTC_GATES_DIR/${gate_type}-results.json"
    local manifest_file="$CURRENT_DIR/$TEST_RESULTS_DIR/$session_name/manifest.json"
    local summary_file="$CURRENT_DIR/$TEST_RESULTS_DIR/$session_name/summary.json"
    
    mkdir -p "$(dirname "$gate_file")"
    
    # Load or initialize gate data
    local gate_data="{}"
    [ -f "$gate_file" ] && gate_data=$(cat "$gate_file")
    
    # Load results
    local manifest=$(cat "$manifest_file" 2>/dev/null || echo '{}')
    local summary=$(cat "$summary_file" 2>/dev/null || echo '{}')
    
    # Merge and update
    echo "$gate_data" | jq \
        --arg session "$session_name" \
        --argjson manifest "$manifest" \
        --argjson summary "$summary" \
        '.[$session] = {
            manifest: $manifest,
            summary: $summary,
            recorded_at: now | todate
        }' > "$gate_file"
    
    log_info "Updated EPCTC gate: $gate_file"
}

# -----------------------------------------------------------------------------
# Parallel Test Execution
# -----------------------------------------------------------------------------

# Run tests in parallel across multiple sandboxes
run_parallel_tests() {
    local test_configs="$1"  # JSON array of test configurations
    local max_parallel="${2:-4}"
    
    log_info "Launching parallel test execution (max: $max_parallel)..."
    
    local pids=()
    local session_names=()
    
    # Parse test configs and launch
    local num_tests=$(echo "$test_configs" | jq 'length')
    
    for ((i=0; i<num_tests; i++)); do
        local config=$(echo "$test_configs" | jq ".[$i]")
        local test_type=$(echo "$config" | jq -r '.type')
        local test_pattern=$(echo "$config" | jq -r '.pattern // ""')
        local isolation=$(echo "$config" | jq -r '.isolation.mode // "namespace"')
        local network=$(echo "$config" | jq -r '.isolation.network // false')
        local docker=$(echo "$config" | jq -r '.isolation.docker // false')
        
        local session_name=$(generate_test_session_name "$test_type")
        session_names+=("$session_name")
        
        # Launch test in background
        (
            log_info "[$session_name] Starting $test_type tests..."
            
            # Initialize session
            local isolation_json=$(jq -n \
                --arg mode "$isolation" \
                --argjson network "$network" \
                --argjson docker "$docker" \
                '{mode: $mode, network: $network, docker: $docker}')
            
            init_test_session "$session_name" "$test_type" "$test_pattern" "$isolation_json"
            
            # Run test in clsecure
            local network_flag=$([ "$network" = "true" ] && echo "--allow-network" || echo "")
            local docker_flag=$([ "$docker" = "true" ] && echo "--allow-docker" || echo "")
            
            clsecure \
                --session "$session_name" \
                --mode "$isolation" \
                $network_flag \
                $docker_flag \
                --shell \
                --skip-setup \
                -- \
                -c "/epctc-test '$test_type' '$test_pattern'" \
                > "$CURRENT_DIR/$TEST_RESULTS_DIR/$session_name/clsecure.log" 2>&1
            
            local exit_code=$?
            
            # Update status
            update_test_session "$session_name" "completed" "$exit_code"
            
            log_info "[$session_name] Completed with exit code: $exit_code"
        ) &
        pids+=($!)
        
        # Limit parallelism
        if [ ${#pids[@]} -ge "$max_parallel" ]; then
            wait "${pids[0]}"
            pids=("${pids[@]:1}")
        fi
    done
    
    # Wait for all to complete
    for pid in "${pids[@]}"; do
        wait "$pid"
    done
    
    # Aggregate results
    aggregate_parallel_results "${session_names[@]}"
}

# Aggregate results from parallel test execution
aggregate_parallel_results() {
    local session_names=("$@")
    
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║           Parallel Test Execution Summary                ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
    
    local total_passed=0
    local total_failed=0
    
    for session_name in "${session_names[@]}"; do
        local manifest_file="$CURRENT_DIR/$TEST_RESULTS_DIR/$session_name/manifest.json"
        local summary_file="$CURRENT_DIR/$TEST_RESULTS_DIR/$session_name/summary.json"
        
        if [ -f "$manifest_file" ]; then
            local test_type=$(jq -r '.test_type' "$manifest_file")
            local status=$(jq -r '.status' "$manifest_file")
            local exit_code=$(jq -r '.exit_code // 1' "$manifest_file")
            
            local status_icon=$([ "$exit_code" -eq 0 ] && echo "✓" || echo "✗")
            
            printf "  %-20s %s %-10s\n" "$test_type:" "$status_icon" "$status"
            
            if [ "$exit_code" -eq 0 ]; then
                ((total_passed++))
            else
                ((total_failed++))
            fi
        fi
    done
    
    echo ""
    echo "Results: $total_passed passed, $total_failed failed"
    
    return $([ "$total_failed" -eq 0 ] && echo 0 || echo 1)
}

# -----------------------------------------------------------------------------
# Utility Functions
# -----------------------------------------------------------------------------

# List all test sessions
list_test_sessions() {
    local results_dir="$CURRENT_DIR/$TEST_RESULTS_DIR"
    
    if [ ! -d "$results_dir" ]; then
        log_info "No test sessions found"
        return 0
    fi
    
    echo ""
    echo "Test Sessions:"
    echo ""
    
    for manifest in "$results_dir"/*/manifest.json; do
        [ -f "$manifest" ] || continue
        
        local session_name=$(jq -r '.session_name' "$manifest")
        local test_type=$(jq -r '.test_type' "$manifest")
        local status=$(jq -r '.status' "$manifest")
        local started_at=$(jq -r '.started_at' "$manifest")
        
        printf "  %-30s %-15s %-15s %s\n" "$session_name" "$test_type" "$status" "$started_at"
    done
}

# Clean up old test sessions
cleanup_test_sessions() {
    local max_age_days="${1:-7}"
    local results_dir="$CURRENT_DIR/$TEST_RESULTS_DIR"
    
    if [ ! -d "$results_dir" ]; then
        return 0
    fi
    
    log_info "Cleaning up test sessions older than $max_age_days days..."
    
    find "$results_dir" -name "manifest.json" -mtime "+$max_age_days" | while read manifest; do
        local session_dir=$(dirname "$manifest")
        local session_name=$(basename "$session_dir")
        
        rm -rf "$session_dir"
        log_info "Removed: $session_name"
    done
    
    log_info "Cleanup complete"
}
