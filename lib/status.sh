#!/bin/bash
# lib/status.sh
#
# Worker session status reporting for clsecure
#
# Dependencies: lib/logging.sh, lib/vars.sh
# Exports: show_worker_status
#
# Usage:
#   source lib/status.sh
#   show_worker_status false   # current project only
#   show_worker_status true    # all workers

# Show status of worker sessions: commits ahead, merge state, uncommitted changes
show_worker_status() {
    local show_all="${1:-false}"
    local host_project="$CURRENT_DIR"
    local host_is_git=false host_branch="" host_short=""

    if [ -d "$host_project/.git" ]; then
        host_is_git=true
        host_branch=$(git -C "$host_project" branch --show-current 2>/dev/null || echo "detached")
        host_short=$(git -C "$host_project" rev-parse --short HEAD 2>/dev/null || echo "unknown")
    fi

    # Discover workers
    local workers
    workers=$(getent passwd | grep "^${WORKER_PREFIX}-" | cut -d: -f1 || true)

    if [ -z "$workers" ]; then
        if [ "$show_all" = true ]; then
            log_info "No worker users found."
        else
            log_info "No workers found for this project. Use --status --all to see all."
        fi
        exit 0
    fi

    # Filter by current project unless --all
    local filtered_workers=()
    for user in $workers; do
        if [ "$show_all" = true ]; then
            filtered_workers+=("$user")
        else
            local wpp
            wpp=$(sudo cat "/home/$user/.clsecure/project_path" 2>/dev/null || echo "")
            if [ "$wpp" = "$CURRENT_DIR" ]; then
                filtered_workers+=("$user")
            fi
        fi
    done

    if [ ${#filtered_workers[@]} -eq 0 ]; then
        if [ "$show_all" = true ]; then
            log_info "No worker users found."
        else
            log_info "No workers found for this project. Use --status --all to see all."
        fi
        exit 0
    fi

    # Print header
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║     Worker Session Status              ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
    echo ""

    if [ "$show_all" = false ] && [ "$host_is_git" = true ]; then
        echo -e "Host: ${CYAN}${host_project}${NC} (${host_branch} @ ${host_short})"
        echo ""
    fi

    # ---- Collect per-worker data ----
    local -a w_users=() w_statuses=() w_sessions=() w_providers=()
    local -a w_aheads=() w_changes=() w_merged_info=()
    local -a w_fork_hashes=() w_fork_subjects=() w_commit_data=()
    local -a w_project_paths=()

    for user in "${filtered_workers[@]}"; do
        local home_dir="/home/$user"
        local project_dir="$home_dir/project"

        w_users+=("$user")

        # Running status
        local lock_file="$LOCK_DIR/${user}.lock"
        local status="idle"
        if [ -f "$lock_file" ]; then
            local pid
            pid=$(cat "$lock_file" 2>/dev/null || echo "")
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                status="RUNNING"
            else
                sudo rm -f "$lock_file" 2>/dev/null || true
            fi
        fi
        w_statuses+=("$status")

        # Session name
        local session="-"
        if [ -f "$home_dir/.clsecure/session_name" ]; then
            session=$(sudo cat "$home_dir/.clsecure/session_name" 2>/dev/null || echo "-")
            [ -z "$session" ] && session="-"
        fi
        w_sessions+=("$session")

        # Provider
        local provider="-"
        if [ -f "$home_dir/.clsecure/provider" ]; then
            provider=$(sudo cat "$home_dir/.clsecure/provider" 2>/dev/null || echo "")
            [ -z "$provider" ] && provider="-"
        fi
        w_providers+=("$provider")

        # Project path (for --all mode detail)
        local wpp
        wpp=$(sudo cat "$home_dir/.clsecure/project_path" 2>/dev/null || echo "-")
        w_project_paths+=("$wpp")

        # Check if worker project dir exists
        if ! sudo test -d "$project_dir/.git" 2>/dev/null; then
            w_aheads+=("?")
            w_changes+=("?")
            w_merged_info+=("?")
            w_fork_hashes+=("")
            w_fork_subjects+=("")
            w_commit_data+=("")
            continue
        fi

        # Get base_commit (fork point)
        local base_commit=""
        if sudo test -f "$home_dir/.clsecure/base_commit" 2>/dev/null; then
            base_commit=$(sudo cat "$home_dir/.clsecure/base_commit" 2>/dev/null || echo "")
        fi

        # Fallback: try origin/main or origin/master in the worker repo
        if [ -z "$base_commit" ]; then
            base_commit=$(sudo -u "$user" git -C "$project_dir" rev-parse origin/main 2>/dev/null ||
                          sudo -u "$user" git -C "$project_dir" rev-parse origin/master 2>/dev/null || echo "")
        fi

        if [ -z "$base_commit" ]; then
            w_aheads+=("?")
            w_changes+=("?")
            w_merged_info+=("no base")
            w_fork_hashes+=("")
            w_fork_subjects+=("")
            w_commit_data+=("")
            continue
        fi

        # Verify base_commit exists in worker history (may be missing in very shallow clones)
        local fork_hash fork_subject
        if ! sudo -u "$user" git -C "$project_dir" cat-file -e "$base_commit" 2>/dev/null; then
            fork_hash="${base_commit:0:8}"
            fork_subject="(shallow clone - base not in history)"
            w_aheads+=("?")
            w_changes+=("$(sudo -u "$user" git -C "$project_dir" status --porcelain 2>/dev/null | wc -l | tr -d ' ')")
            w_merged_info+=("shallow")
            w_fork_hashes+=("$fork_hash")
            w_fork_subjects+=("$fork_subject")
            w_commit_data+=("")
            continue
        fi

        fork_hash="${base_commit:0:8}"
        fork_subject=$(sudo -u "$user" git -C "$project_dir" log -1 --format="%s" "$base_commit" 2>/dev/null || echo "unknown")

        # Commits ahead of fork point
        local ahead_log
        ahead_log=$(sudo -u "$user" git -C "$project_dir" log --format="%h|||%s" "${base_commit}..HEAD" 2>/dev/null || echo "")

        # Uncommitted changes count
        local changes
        changes=$(sudo -u "$user" git -C "$project_dir" status --porcelain 2>/dev/null | wc -l | tr -d ' ')

        # Determine host project for merge checking
        local merge_project="$host_project"
        if [ "$show_all" = true ]; then
            merge_project="$wpp"
        fi
        local can_check_merge=false
        if [ -d "$merge_project/.git" ]; then
            can_check_merge=true
        fi

        # Process commits and check merge status
        local ahead=0 merged_count=0
        local commit_lines=""

        if [ -n "$ahead_log" ]; then
            while IFS= read -r line; do
                [ -z "$line" ] && continue
                ahead=$((ahead + 1))

                local c_hash="${line%%|||*}"
                local c_subject="${line#*|||}"

                local is_merged="MISSING"
                if [ "$can_check_merge" = true ]; then
                    local found
                    found=$(git -C "$merge_project" log --oneline --all --grep="$c_subject" --fixed-strings 2>/dev/null || echo "")
                    if [ -n "$found" ]; then
                        is_merged="MERGED"
                        merged_count=$((merged_count + 1))
                    fi
                fi

                if [ -z "$commit_lines" ]; then
                    commit_lines="${c_hash}|||${c_subject}|||${is_merged}"
                else
                    commit_lines+=$'\n'"${c_hash}|||${c_subject}|||${is_merged}"
                fi
            done <<< "$ahead_log"
        fi

        w_aheads+=("$ahead")
        w_changes+=("$changes")
        if [ "$ahead" -eq 0 ]; then
            w_merged_info+=("-")
        elif [ "$merged_count" -eq "$ahead" ]; then
            w_merged_info+=("${merged_count}/${ahead} ALL")
        else
            w_merged_info+=("${merged_count}/${ahead}")
        fi
        w_fork_hashes+=("$fork_hash")
        w_fork_subjects+=("$fork_subject")
        w_commit_data+=("$commit_lines")
    done

    # ---- Print summary table ----
    printf "%-35s %-9s %-12s %-10s %-6s %-8s %s\n" \
        "WORKER" "STATUS" "SESSION" "PROVIDER" "AHEAD" "CHANGES" "MERGED"
    printf "%-35s %-9s %-12s %-10s %-6s %-8s %s\n" \
        "------" "------" "-------" "--------" "-----" "-------" "------"

    for i in "${!w_users[@]}"; do
        local status_display="${w_statuses[$i]}"
        if [ "$status_display" = "RUNNING" ]; then
            status_display="${YELLOW}RUNNING${NC}"
        fi
        printf "%-35s %-9b %-12s %-10s %-6s %-8s %s\n" \
            "${w_users[$i]}" "$status_display" "${w_sessions[$i]}" \
            "${w_providers[$i]}" "${w_aheads[$i]}" "${w_changes[$i]}" \
            "${w_merged_info[$i]}"
    done

    # ---- Print detail sections ----
    for i in "${!w_users[@]}"; do
        local ahead="${w_aheads[$i]}"
        local changes="${w_changes[$i]}"

        # Skip detail for workers with no interesting data
        if [ "$ahead" = "0" ] && [ "$changes" = "0" ]; then
            continue
        fi
        # Also skip if both are unknown and no fork info
        if [ "$ahead" = "?" ] && [ -z "${w_fork_hashes[$i]}" ]; then
            continue
        fi

        echo ""
        echo -e "─── ${CYAN}${w_users[$i]}${NC} (${w_sessions[$i]}) ───"

        # Show project path in --all mode
        if [ "$show_all" = true ]; then
            echo "  Project: ${w_project_paths[$i]}"
        fi

        if [ -n "${w_fork_hashes[$i]}" ]; then
            echo "  Fork: ${w_fork_hashes[$i]} (${w_fork_subjects[$i]})"
        fi

        if [ "$ahead" != "?" ] && [ "$ahead" -gt 0 ] 2>/dev/null; then
            local merged_info="${w_merged_info[$i]}"
            if [[ "$merged_info" == *"ALL"* ]]; then
                echo -e "  ${GREEN}ALL MERGED${NC} ($ahead commits)"
            else
                local mc="${merged_info%%/*}"
                local missing=$((ahead - mc))
                echo "  $ahead commits ahead ($mc merged, $missing missing)"
            fi
            echo ""

            # Print individual commits
            local commit_data="${w_commit_data[$i]}"
            if [ -n "$commit_data" ]; then
                while IFS= read -r cline; do
                    [ -z "$cline" ] && continue
                    local c_hash="${cline%%|||*}"
                    local rest="${cline#*|||}"
                    local c_subject="${rest%|||*}"
                    local c_status="${rest##*|||}"

                    if [ "$c_status" = "MERGED" ]; then
                        echo -e "     ${GREEN}[MERGED ]${NC} $c_hash $c_subject"
                    else
                        echo -e "  >> ${YELLOW}[MISSING]${NC} $c_hash $c_subject"
                    fi
                done <<< "$commit_data"
            fi
        fi

        if [ "$changes" != "0" ] && [ "$changes" != "?" ]; then
            echo "  Uncommitted: $changes files"
        fi
    done

    echo ""
    exit 0
}
