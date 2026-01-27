#!/bin/bash
# lib/deps.sh
#
# Dependency installation for clsecure
#
# Dependencies: lib/logging.sh, lib/worker.sh, lib/vars.sh
# Exports: install_project_dependencies, run_setup_script, copy_npm_cache, install_task_master
#
# Usage:
#   source lib/deps.sh
#   install_project_dependencies

# Copy npm cache from invoking user to worker user
# This speeds up npm installs significantly by avoiding re-downloads
copy_npm_cache() {
    local source_cache="${HOME}/.npm"
    local dest_cache="${WORKER_HOME}/.npm"

    if [ ! -d "$source_cache" ]; then
        log_info "No npm cache found at $source_cache, skipping cache copy."
        return 0
    fi

    if [ -d "$dest_cache" ]; then
        log_info "Worker npm cache already exists."
        return 0
    fi

    log_info "Copying npm cache to worker user..."
    sudo cp -r "$source_cache" "$dest_cache"
    sudo chown -R "$WORKER_USER:$WORKER_USER" "$dest_cache"
    log_info "npm cache copied successfully."
}

# Install task-master-ai with retry logic
# Args: $1 = max retries (default 2)
install_task_master() {
    local max_retries="${1:-2}"
    local attempt=1

    log_step "Checking task-master-ai..."

    # Check if already installed
    if sudo -u "$WORKER_USER" bash -c "cd && source ~/.bashrc && command -v task-master" &>/dev/null; then
        log_info "task-master-ai already installed."
        return 0
    fi

    # Copy npm cache first to speed up installation
    copy_npm_cache

    while [ $attempt -le $max_retries ]; do
        log_info "Installing task-master-ai (attempt $attempt/$max_retries)..."

        # Install with increased timeout (5 minutes)
        if sudo -u "$WORKER_USER" bash -c "cd && source ~/.bashrc && npm install -g task-master-ai --fetch-timeout=300000 --fetch-retries=3" 2>&1; then
            log_info "task-master-ai installed successfully."
            return 0
        fi

        log_warn "Attempt $attempt failed."
        attempt=$((attempt + 1))

        if [ $attempt -le $max_retries ]; then
            log_info "Retrying in 5 seconds..."
            sleep 5
        fi
    done

    log_warn "Failed to install task-master-ai after $max_retries attempts. Continuing anyway..."
    return 1
}

# Install project dependencies (npm/pip)
install_project_dependencies() {
    log_step "Installing project dependencies..."
    
    if [ -f "$WORKER_PROJECT/package.json" ]; then
        log_info "Found package.json, running npm install..."
        sudo -u "$WORKER_USER" bash -c "cd '$WORKER_PROJECT' && source \"$WORKER_HOME/.bashrc\" && npm install"
    fi

    if [ -f "$WORKER_PROJECT/requirements.txt" ]; then
        log_info "Found requirements.txt..."
        if [ ! -d "$WORKER_PROJECT/venv" ] && [ ! -d "$WORKER_PROJECT/.venv" ]; then
            log_info "Creating virtual environment..."
            sudo -u "$WORKER_USER" bash -c "cd '$WORKER_PROJECT' && python3 -m venv venv"
        fi
        
        local venv_dir="$WORKER_PROJECT/venv"
        if [ -d "$WORKER_PROJECT/.venv" ]; then
            venv_dir="$WORKER_PROJECT/.venv"
        fi
        
        log_info "Installing pip requirements in $venv_dir..."
        sudo -u "$WORKER_USER" bash -c "source '$venv_dir/bin/activate' && pip install -r '$WORKER_PROJECT/requirements.txt'"
    fi
}

# Run setup script if configured
run_setup_script() {
    if [ -z "$SETUP_SCRIPT" ]; then
        return 0
    fi

    log_step "Running setup script..."
    if [ ! -f "$SETUP_SCRIPT" ]; then
        log_warn "Setup script configured but not found: $SETUP_SCRIPT"
        return 1
    fi

    local worker_setup_script="$WORKER_HOME/setup_script.sh"
    sudo cp "$SETUP_SCRIPT" "$worker_setup_script"
    sudo chown "$WORKER_USER:$WORKER_USER" "$worker_setup_script"
    sudo chmod +x "$worker_setup_script"
    
    # Capture GH_TOKEN if available
    # Priority: Env var -> gh auth token
    local gh_token_val="${GH_TOKEN:-}"
    if [ -z "$gh_token_val" ] && command -v gh &>/dev/null; then
         gh_token_val=$(gh auth token 2>/dev/null || echo "")
    fi

    log_info "Executing $SETUP_SCRIPT..."
    if [ -n "$gh_token_val" ]; then
         if sudo -u "$WORKER_USER" GH_TOKEN="$gh_token_val" bash -c "cd && source ~/.bashrc && $worker_setup_script"; then
             log_info "Setup script executed successfully."
             return 0
         else
             log_warn "Setup script failed."
             return 1
         fi
    else
         if sudo -u "$WORKER_USER" bash -c "cd && source ~/.bashrc && $worker_setup_script"; then
             log_info "Setup script executed successfully."
             return 0
         else
             log_warn "Setup script failed."
             return 1
         fi
    fi
}
