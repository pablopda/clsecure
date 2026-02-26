#!/bin/bash
# lib/deps.sh
#
# Dependency installation for clsecure
#
# Dependencies: lib/logging.sh, lib/worker.sh, lib/vars.sh
# Exports: install_project_dependencies, run_setup_script
#
# Usage:
#   source lib/deps.sh
#   install_project_dependencies

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
