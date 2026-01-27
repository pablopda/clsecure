#!/bin/bash
# lib/worker.sh
# 
# Worker user management for clsecure
# 
# Dependencies: lib/logging.sh, lib/config.sh, lib/vars.sh
# Exports: list_workers, cleanup_workers, cleanup_all_workers, check_worker_exists, create_worker_user, setup_worker_home
# 
# Usage:
#   source lib/worker.sh
#   create_worker_user

# List all worker users and their status
list_workers() {
    echo ""
    echo -e "${GREEN}Claude Worker Users:${NC}"
    echo ""

    local workers=$(getent passwd | grep "^${WORKER_PREFIX}-" | cut -d: -f1 || true)

    if [ -z "$workers" ]; then
        log_info "No worker users found."
        exit 0
    fi

    printf "%-30s %-10s %-15s %s\n" "USER" "STATUS" "SIZE" "PROJECT PATH"
    printf "%-30s %-10s %-15s %s\n" "----" "------" "----" "------------"

    for user in $workers; do
        local home_dir="/home/$user"
        local lock_file="$LOCK_DIR/${user}.lock"
        local status="idle"

        if [ -f "$lock_file" ]; then
            local pid=$(cat "$lock_file" 2>/dev/null || echo "")
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                status="${YELLOW}RUNNING${NC}"
            else
                sudo rm -f "$lock_file" 2>/dev/null || true
            fi
        fi

        local size="N/A"
        if [ -d "$home_dir" ]; then
            size=$(sudo du -sh "$home_dir" 2>/dev/null | cut -f1 || echo "N/A")
        fi

        local project_path="-"
        if [ -d "$home_dir/project/.git" ]; then
            project_path=$(sudo -u "$user" git -C "$home_dir/project" remote get-url origin 2>/dev/null | sed 's|.*/||' | sed 's|\.git$||' || echo "-")
        fi

        printf "%-30s %-10b %-15s %s\n" "$user" "$status" "$size" "$project_path"
    done

    echo ""
    exit 0
}

# Interactively cleanup specific worker users
cleanup_workers() {
    echo ""
    echo -e "${GREEN}Claude Worker Users Cleanup:${NC}"
    echo ""

    local workers=$(getent passwd | grep "^${WORKER_PREFIX}-" | cut -d: -f1 || true)

    if [ -z "$workers" ]; then
        log_info "No worker users found."
        exit 0
    fi

    local worker_array=($workers)

    echo "Found worker users:"
    for i in "${!worker_array[@]}"; do
        local user="${worker_array[$i]}"
        local lock_file="$LOCK_DIR/${user}.lock"
        local status=""

        if [ -f "$lock_file" ]; then
            local pid=$(cat "$lock_file" 2>/dev/null || echo "")
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                status=" ${YELLOW}(RUNNING - cannot remove)${NC}"
            fi
        fi

        echo -e "  $((i+1))) ${user}${status}"
    done
    echo "  q) Quit"
    echo ""

    read -p "Select user to remove (number or 'q'): " selection

    if [[ "$selection" == "q" || "$selection" == "Q" ]]; then
        exit 0
    fi

    if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le ${#worker_array[@]} ]; then
        local user="${worker_array[$((selection-1))]}"
        local lock_file="$LOCK_DIR/${user}.lock"

        if [ -f "$lock_file" ]; then
            local pid=$(cat "$lock_file" 2>/dev/null || echo "")
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                log_error "Cannot remove '$user' - session is still running (PID: $pid)"
                exit 1
            fi
        fi

        echo ""
        read -p "Remove user '$user' and all their files? (y/n): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            log_info "Removing user '$user'..."
            sudo userdel -r "$user" 2>/dev/null || sudo userdel "$user" 2>/dev/null || true
            sudo rm -rf "/home/$user" 2>/dev/null || true
            sudo rm -f "$lock_file" 2>/dev/null || true
            log_info "Done."
        else
            log_info "Cancelled."
        fi
    else
        log_error "Invalid selection."
        exit 1
    fi

    exit 0
}

# Remove ALL worker users (requires confirmation)
cleanup_all_workers() {
    echo ""
    echo -e "${RED}WARNING: This will remove ALL claude-worker users and their files.${NC}"
    echo ""

    local workers=$(getent passwd | grep "^${WORKER_PREFIX}-" | cut -d: -f1 || true)

    if [ -z "$workers" ]; then
        log_info "No worker users found."
        exit 0
    fi

    echo "Users to be removed:"
    for user in $workers; do
        echo "  - $user"
    done
    echo ""

    read -p "Type 'DELETE ALL' to confirm: " confirm
    if [ "$confirm" = "DELETE ALL" ]; then
        for user in $workers; do
            local lock_file="$LOCK_DIR/${user}.lock"

            if [ -f "$lock_file" ]; then
                local pid=$(cat "$lock_file" 2>/dev/null || echo "")
                if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                    log_warn "Skipping '$user' - still running (PID: $pid)"
                    continue
                fi
            fi

            log_info "Removing '$user'..."
            sudo userdel -r "$user" 2>/dev/null || sudo userdel "$user" 2>/dev/null || true
            sudo rm -rf "/home/$user" 2>/dev/null || true
            sudo rm -f "$lock_file" 2>/dev/null || true
        done
        log_info "Done."
    else
        log_info "Cancelled."
    fi

    exit 0
}

# Check if worker user exists
check_worker_exists() {
    id "$WORKER_USER" &>/dev/null
}

# Create worker user if it doesn't exist
create_worker_user() {
    if ! check_worker_exists; then
        log_info "Creating user '$WORKER_USER'..."
        sudo useradd -m -s /bin/bash "$WORKER_USER"
        log_info "User created."
    else
        log_info "User already exists."
    fi

    # Add to docker group if docker exists and docker access is allowed
    if command -v docker &>/dev/null && [ "$ALLOW_DOCKER" = true ]; then
        if ! groups "$WORKER_USER" 2>/dev/null | grep -q '\bdocker\b'; then
            log_warn "Adding worker to docker group (grants root-equivalent access)"
            log_info "Adding to docker group..."
            sudo usermod -aG docker "$WORKER_USER"
        fi
    fi
}

# Setup worker home directory (permissions, ownership)
setup_worker_home() {
    sudo chown -R "$WORKER_USER:$WORKER_USER" "$WORKER_HOME"
    sudo chmod 755 "$WORKER_HOME"
}
