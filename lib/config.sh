#!/bin/bash
# lib/config.sh
#
# Configuration loading and validation for clsecure
#
# Dependencies: lib/logging.sh, lib/vars.sh
# Exports: load_config, show_config_info
# Internal: _parse_config_file, _trim
#
# Usage:
#   source lib/config.sh
#   load_config

# Keys that are safe to set from project-level config (allow-list).
# Any recognized key NOT in this list is rejected from project config with a warning.
# When adding new config keys, they default to user-only unless added here.
_PROJECT_SAFE_KEYS="|mode|isolation_mode|ISOLATION_MODE|cleanup_hook_timeout|CLEANUP_HOOK_TIMEOUT|skip_docker_autodetect|SKIP_DOCKER_AUTODETECT|"

# Trim leading and trailing whitespace using pure bash (no subshell/xargs).
_trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# Actionable hint for a rejected project-config key.
_project_key_hint() {
    local key="$1"
    case "$key" in
        network|allow_network|ALLOW_NETWORK)
            echo "use --allow-network/--no-network or set in ~/.config/clsecure/config" ;;
        docker|allow_docker|ALLOW_DOCKER)
            echo "use --allow-docker or set in ~/.config/clsecure/config" ;;
        setup_script|SETUP_SCRIPT)
            echo "set setup_script in ~/.config/clsecure/config" ;;
        install_dependencies|INSTALL_DEPS)
            echo "use --install-deps or set in ~/.config/clsecure/config" ;;
        provider|PROVIDER)
            echo "use --provider or set in ~/.config/clsecure/config" ;;
        kimi_api_key|KIMI_API_KEY)
            echo "set in ~/.config/clsecure/config or export KIMI_API_KEY" ;;
        *)
            echo "set in ~/.config/clsecure/config" ;;
    esac
}

# Parse a config file and apply settings.
# Arguments:
#   $1 - path to config file
#   $2 - "project" to restrict to safe keys (allow-list), "user" for all keys
_parse_config_file() {
    local config_file="$1"
    local scope="${2:-user}"

    while IFS='=' read -r key value || [ -n "$key" ]; do
        # Skip comments and empty lines
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$key" ]] && continue

        # Trim whitespace (pure bash, no subshells)
        key=$(_trim "$key")
        value=$(_trim "$value")

        # Remove quotes from value if present
        value="${value#\"}"
        value="${value%\"}"
        value="${value#\'}"
        value="${value%\'}"

        # In project scope, only allow keys on the allow-list.
        # Any recognized key not on the list is warned and skipped.
        # Unrecognized keys fall through both gates harmlessly.
        if [ "$scope" = "project" ] && [[ "$_PROJECT_SAFE_KEYS" != *"|${key}|"* ]]; then
            # Only warn for keys we actually recognise (avoid noise for typos/comments)
            case "$key" in
                network|allow_network|ALLOW_NETWORK|\
                docker|allow_docker|ALLOW_DOCKER|\
                setup_script|SETUP_SCRIPT|\
                install_dependencies|INSTALL_DEPS|\
                provider|PROVIDER|\
                kimi_api_key|KIMI_API_KEY)
                    log_warn "Project config requests '$key=$value' — ignored ($(_project_key_hint "$key"))"
                    ;;
            esac
            continue
        fi

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
            provider|PROVIDER)
                if [[ "$value" =~ ^(kimi|anthropic)$ ]]; then
                    PROVIDER="$value"
                    [ "$value" = "anthropic" ] && PROVIDER=""
                else
                    log_warn "Invalid provider '$value' in config (must be anthropic or kimi)"
                fi
                ;;
            kimi_api_key|KIMI_API_KEY)
                if [ -n "$value" ]; then
                    KIMI_API_KEY="$value"
                fi
                ;;
        esac
    done < "$config_file"
}

# Load configuration from project and user config files.
# Precedence: CLI flags > user config > project config > defaults
load_config() {
    # Detect misplaced project config
    if [ -f "${CURRENT_DIR}/.clsecure.conf" ] && [ ! -f "$PROJECT_CONFIG_FILE" ]; then
        log_warn "Found .clsecure.conf in project root (ignored). Use .clsecure/config instead."
    fi

    # Step 1: Load project config (safe keys only)
    if [ -f "$PROJECT_CONFIG_FILE" ]; then
        _parse_config_file "$PROJECT_CONFIG_FILE" "project"
    fi

    # Step 2: Load user config (all keys — overwrites project config values)
    local user_config=""
    if [ -f "$CONFIG_FILE" ]; then
        user_config="$CONFIG_FILE"
    elif [ -f "$CONFIG_FILE_ALT" ]; then
        user_config="$CONFIG_FILE_ALT"
    fi

    if [ -n "$user_config" ]; then
        _parse_config_file "$user_config" "user"
    fi
}

# Check if a config value is valid for its key.
# Returns 0 if valid, 1 otherwise.
_is_valid_config_value() {
    local key="$1"
    local value="$2"
    case "$key" in
        mode|isolation_mode|ISOLATION_MODE)
            [[ "$value" =~ ^(user|namespace|container)$ ]] ;;
        network|allow_network|ALLOW_NETWORK|\
        docker|allow_docker|ALLOW_DOCKER|\
        install_dependencies|INSTALL_DEPS|\
        skip_docker_autodetect|SKIP_DOCKER_AUTODETECT)
            [[ "$value" =~ ^(true|false|yes|no|1|0)$ ]] ;;
        setup_script|SETUP_SCRIPT)
            [ -n "$value" ] ;;
        cleanup_hook_timeout|CLEANUP_HOOK_TIMEOUT)
            [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -ge 5 ] && [ "$value" -le 300 ] ;;
        provider|PROVIDER)
            [[ "$value" =~ ^(anthropic|kimi)$ ]] ;;
        kimi_api_key|KIMI_API_KEY)
            [ -n "$value" ] ;;
        *)
            return 1 ;;
    esac
}

show_config_info() {
    local user_config=""
    if [ -f "$CONFIG_FILE" ]; then
        user_config="$CONFIG_FILE"
    elif [ -f "$CONFIG_FILE_ALT" ]; then
        user_config="$CONFIG_FILE_ALT"
    fi

    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║     Configuration                      ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
    echo ""

    # Show project config
    if [ -f "$PROJECT_CONFIG_FILE" ]; then
        echo -e "${GREEN}Project config:${NC} $PROJECT_CONFIG_FILE"
        echo ""
        echo "Current contents:"
        sed 's/^/  /' "$PROJECT_CONFIG_FILE"
        echo ""
    else
        echo -e "${YELLOW}No project config found.${NC}"
        echo "  Create one at: .clsecure/config"
        echo ""
    fi

    # Show user config
    if [ -n "$user_config" ]; then
        echo -e "${GREEN}User config:${NC} $user_config"
        echo ""
        echo "Current contents:"
        sed 's/^/  /' "$user_config"
    else
        echo -e "${YELLOW}No user config found.${NC}"
        echo "  Create one at: $CONFIG_FILE"
    fi

    echo ""
    echo -e "${CYAN}Effective settings:${NC}"
    echo ""

    # Save effective values (already loaded by load_config)
    local eff_mode="$ISOLATION_MODE"
    local eff_network="$ALLOW_NETWORK"
    local eff_docker="$ALLOW_DOCKER"
    local eff_deps="$INSTALL_DEPS"
    local eff_setup="$SETUP_SCRIPT"
    local eff_cleanup_timeout="$CLEANUP_HOOK_TIMEOUT"
    local eff_skip_docker_auto="$SKIP_DOCKER_AUTODETECT"
    local eff_provider="${PROVIDER:-anthropic}"
    [ -z "$PROVIDER" ] && eff_provider="anthropic"
    local eff_kimi_key="<not set>"
    if [ -n "$KIMI_API_KEY" ]; then
        eff_kimi_key="${KIMI_API_KEY:0:10}..."
    fi

    # Determine provenance labels
    local src_mode="default" src_network="default" src_docker="default"
    local src_deps="default" src_setup="default" src_cleanup_timeout="default"
    local src_skip_docker_auto="default" src_provider="default" src_kimi_key="default"
    # Check env vars for provider settings
    [ -n "${PROVIDER:-}" ] && src_provider="env/cli"
    [ -n "${KIMI_API_KEY:-}" ] && src_kimi_key="env"

    # Check project config for safe keys (only mark provenance if value is valid)
    if [ -f "$PROJECT_CONFIG_FILE" ]; then
        while IFS='=' read -r key value || [ -n "$key" ]; do
            [[ "$key" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$key" ]] && continue
            key=$(_trim "$key")
            value=$(_trim "$value")
            value="${value#\"}" ; value="${value%\"}"
            value="${value#\'}" ; value="${value%\'}"
            # Only mark provenance for safe keys with valid values
            if [[ "$_PROJECT_SAFE_KEYS" == *"|${key}|"* ]] && _is_valid_config_value "$key" "$value"; then
                case "$key" in
                    mode|isolation_mode|ISOLATION_MODE) src_mode="project" ;;
                    cleanup_hook_timeout|CLEANUP_HOOK_TIMEOUT) src_cleanup_timeout="project" ;;
                    skip_docker_autodetect|SKIP_DOCKER_AUTODETECT) src_skip_docker_auto="project" ;;
                esac
            fi
        done < "$PROJECT_CONFIG_FILE"
    fi

    # Check user config for all keys (overrides project provenance, only if valid)
    if [ -n "$user_config" ]; then
        while IFS='=' read -r key value || [ -n "$key" ]; do
            [[ "$key" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$key" ]] && continue
            key=$(_trim "$key")
            value=$(_trim "$value")
            value="${value#\"}" ; value="${value%\"}"
            value="${value#\'}" ; value="${value%\'}"
            if _is_valid_config_value "$key" "$value"; then
                case "$key" in
                    mode|isolation_mode|ISOLATION_MODE) src_mode="user" ;;
                    network|allow_network|ALLOW_NETWORK) src_network="user" ;;
                    docker|allow_docker|ALLOW_DOCKER) src_docker="user" ;;
                    install_dependencies|INSTALL_DEPS) src_deps="user" ;;
                    setup_script|SETUP_SCRIPT) src_setup="user" ;;
                    cleanup_hook_timeout|CLEANUP_HOOK_TIMEOUT) src_cleanup_timeout="user" ;;
                    skip_docker_autodetect|SKIP_DOCKER_AUTODETECT) src_skip_docker_auto="user" ;;
                    provider|PROVIDER) src_provider="user" ;;
                    kimi_api_key|KIMI_API_KEY) src_kimi_key="user" ;;
                esac
            fi
        done < "$user_config"
    fi

    echo "  mode = $eff_mode  [$src_mode]"
    echo "  network = $eff_network  [$src_network]"
    echo "  docker = $eff_docker  [$src_docker]"
    echo "  install_dependencies = $eff_deps  [$src_deps]"
    echo "  setup_script = ${eff_setup:-<none>}  [$src_setup]"
    echo "  cleanup_hook_timeout = $eff_cleanup_timeout  [$src_cleanup_timeout]"
    echo "  skip_docker_autodetect = $eff_skip_docker_auto  [$src_skip_docker_auto]"
    echo "  provider = $eff_provider  [$src_provider]"
    echo "  kimi_api_key = $eff_kimi_key  [$src_kimi_key]"
    echo ""
    echo "Precedence: CLI args > User config > Project config > Defaults"
    echo ""
    echo -e "${YELLOW}Note:${NC} Project config (.clsecure/config) can only set:"
    echo "  mode, cleanup_hook_timeout, skip_docker_autodetect"
    echo ""

    exit 0
}
