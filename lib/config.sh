#!/bin/bash
# lib/config.sh
# 
# Configuration loading and validation for clsecure
# 
# Dependencies: lib/logging.sh, lib/vars.sh
# Exports: load_config, show_config_info
# 
# Usage:
#   source lib/config.sh
#   load_config

# Load configuration file
load_config() {
    local config_file=""

    # Check for config file (XDG location first, then fallback)
    if [ -f "$CONFIG_FILE" ]; then
        config_file="$CONFIG_FILE"
    elif [ -f "$CONFIG_FILE_ALT" ]; then
        config_file="$CONFIG_FILE_ALT"
    else
        return 0  # No config file, use defaults
    fi

    # Parse config file (simple key=value format, ignore comments and empty lines)
    while IFS='=' read -r key value || [ -n "$key" ]; do
        # Skip comments and empty lines
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$key" ]] && continue

        # Trim whitespace
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)

        # Remove quotes from value if present
        value="${value#\"}"
        value="${value%\"}"
        value="${value#\'}"
        value="${value%\'}"

        case "$key" in
            mode|isolation_mode|ISOLATION_MODE)
                if [[ "$value" =~ ^(user|namespace|container)$ ]]; then
                    ISOLATION_MODE="$value"
                fi
                ;;
            network|allow_network|ALLOW_NETWORK)
                if [[ "$value" =~ ^(true|false|yes|no|1|0)$ ]]; then
                    [[ "$value" =~ ^(true|yes|1)$ ]] && ALLOW_NETWORK=true || ALLOW_NETWORK=false
                fi
                ;;
            docker|allow_docker|ALLOW_DOCKER)
                if [[ "$value" =~ ^(true|false|yes|no|1|0)$ ]]; then
                    [[ "$value" =~ ^(true|yes|1)$ ]] && ALLOW_DOCKER=true || ALLOW_DOCKER=false
                fi
                ;;
            install_dependencies|INSTALL_DEPS)
                if [[ "$value" =~ ^(true|false|yes|no|1|0)$ ]]; then
                    [[ "$value" =~ ^(true|yes|1)$ ]] && INSTALL_DEPS=true || INSTALL_DEPS=false
                fi
                ;;
            setup_script|SETUP_SCRIPT)
                if [ -n "$value" ]; then
                    SETUP_SCRIPT="$value"
                fi
                ;;
            cleanup_hook_timeout|CLEANUP_HOOK_TIMEOUT)
                if [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -ge 5 ] && [ "$value" -le 300 ]; then
                    CLEANUP_HOOK_TIMEOUT="$value"
                fi
                ;;
            skip_docker_autodetect|SKIP_DOCKER_AUTODETECT)
                if [[ "$value" =~ ^(true|false|yes|no|1|0)$ ]]; then
                    [[ "$value" =~ ^(true|yes|1)$ ]] && SKIP_DOCKER_AUTODETECT=true || SKIP_DOCKER_AUTODETECT=false
                fi
                ;;
        esac
    done < "$config_file"
}

show_config_info() {
    local config_file=""
    if [ -f "$CONFIG_FILE" ]; then
        config_file="$CONFIG_FILE"
    elif [ -f "$CONFIG_FILE_ALT" ]; then
        config_file="$CONFIG_FILE_ALT"
    fi

    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║     Configuration                      ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
    echo ""

    if [ -n "$config_file" ]; then
        echo -e "${GREEN}Config file:${NC} $config_file"
        echo ""
        echo "Current contents:"
        cat "$config_file" | sed 's/^/  /'
    else
        echo -e "${YELLOW}No config file found.${NC}"
        echo ""
        echo "Create one at: $CONFIG_FILE"
    fi

    echo ""
    echo "Example configuration:"
    echo ""
    echo "  # Default isolation mode: user, namespace, or container"
    echo "  mode = namespace"
    echo ""
    echo "  # Allow network access (true/false)"
    echo "  network = true"
    echo ""
    echo "  # Allow Docker access (true/false)"
    echo "  docker = false"
    echo ""
    exit 0
}
