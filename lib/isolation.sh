#!/bin/bash
# lib/isolation.sh
# 
# Isolation mode execution for clsecure
# 
# Dependencies: lib/logging.sh, lib/config.sh, lib/worker.sh, lib/vars.sh
# Exports: check_isolation_requirements, show_isolation_info, start_user_session, start_namespace_session
# 
# Usage:
#   source lib/isolation.sh
#   check_isolation_requirements

# Check isolation requirements (firejail/podman)
check_isolation_requirements() {
    case $ISOLATION_MODE in
        namespace)
            if ! command -v firejail &>/dev/null; then
                log_error "Firejail not found. Install with: sudo apt install firejail"
                log_info "Or use --mode user for basic isolation"
                exit 1
            fi
            log_security "Namespace isolation enabled (firejail)"
            ;;
        user)
            log_security "User isolation enabled (basic)"
            ;;
    esac
}

# Show isolation information
show_isolation_info() {
    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║     Isolation Configuration            ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
    echo ""

    echo -e "${GREEN}Current Mode:${NC} $ISOLATION_MODE"
    echo -e "${GREEN}Network:${NC} $([ "$ALLOW_NETWORK" = true ] && echo "Enabled" || echo "Disabled (--net=none)")"
    echo -e "${GREEN}Docker:${NC} $([ "$ALLOW_DOCKER" = true ] && echo "Enabled" || echo "Disabled")"
    echo -e "${GREEN}Install Deps:${NC} $([ "$INSTALL_DEPS" = true ] && echo "Enabled" || echo "Disabled")"
    if [ -n "$SETUP_SCRIPT" ]; then
        echo -e "${GREEN}Setup Script:${NC} $SETUP_SCRIPT"
    fi
    echo ""

    case $ISOLATION_MODE in
        user)
            echo -e "${YELLOW}User Isolation Only${NC}"
            echo "  ✓ Dedicated user: $WORKER_USER"
            echo "  ✓ Separate home directory"
            echo "  ✓ File system permissions"
            echo "  ✗ No namespace isolation"
            echo "  ✗ No capability restrictions"
            echo ""
            echo -e "${YELLOW}Security Level: 6/10${NC}"
            echo "Good for: Regular development on trusted code"
            ;;
        namespace)
            echo -e "${GREEN}User + Namespace Isolation (Recommended)${NC}"
            echo "  ✓ Dedicated user: $WORKER_USER"
            echo "  ✓ Separate home directory"
            echo "  ✓ Firejail sandbox"
            echo "  ✓ Network isolation (unless --allow-network)"
            echo "  ✓ PID namespace (process isolation)"
            echo "  ✓ Mount namespace (filesystem isolation)"
            echo "  ✓ Capability dropping (no CAP_SYS_ADMIN, etc.)"
            echo "  ✓ Seccomp filters (blocks dangerous syscalls)"
            echo "  ✓ Device isolation (no /dev/video, /dev/audio)"
            if [ "$ALLOW_DOCKER" = true ]; then
                echo -e "  ${YELLOW}⚠ Docker access enabled (User Namespace disabled)${NC}"
            else
                echo "  ✓ User Namespace (noroot)"
            fi
            echo ""
            echo -e "${GREEN}Security Level: 8/10${NC}"
            echo "Good for: Most use cases, excellent security/usability balance"
            ;;
    esac

    echo ""
    echo -e "${BLUE}Threat Protection:${NC}"

    case $ISOLATION_MODE in
        user)
            echo "  File access outside project:  Protected (user permissions)"
            echo "  Network exfiltration:         Vulnerable"
            echo "  Privilege escalation:         Limited protection"
            echo "  Process interference:         Limited protection"
            echo "  Device access:                Vulnerable"
            ;;
        namespace)
            echo "  File access outside project:  Hardened (explicit mounts)"
            echo "  Network exfiltration:         $([ "$ALLOW_NETWORK" = true ] && echo "Vulnerable" || echo "Blocked")"
            echo "  Privilege escalation:         Blocked"
            echo "  Process interference:         Blocked (PID namespace)"
            echo "  Device access:                Blocked"
            ;;
    esac

    echo ""
    exit 0
}

# Build env args array for session environment variables
# Forwards CLSECURE_SESSION, GH_TOKEN, and Claude Code API env vars
_build_session_env() {
    SESSION_ENV_ARGS=()
    if [ -n "${SESSION_NAME:-}" ]; then
        SESSION_ENV_ARGS+=(CLSECURE_SESSION="$SESSION_NAME")
    fi

    local gh_token_val="${GH_TOKEN:-}"
    if [ -z "$gh_token_val" ] && command -v gh &>/dev/null; then
        gh_token_val=$(gh auth token 2>/dev/null || echo "")
    fi
    if [ -n "$gh_token_val" ]; then
        SESSION_ENV_ARGS+=(GH_TOKEN="$gh_token_val")
    fi

    # Provider-specific API configuration
    if [ "${PROVIDER:-}" = "kimi" ]; then
        SESSION_ENV_ARGS+=(ANTHROPIC_BASE_URL="https://api.kimi.com/coding/")
        SESSION_ENV_ARGS+=(ANTHROPIC_API_KEY="$KIMI_API_KEY")
        SESSION_ENV_ARGS+=(CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1)
    fi

    # Forward Claude Code API configuration env vars (for manual/custom providers)
    local api_vars=(
        ANTHROPIC_BASE_URL
        ANTHROPIC_AUTH_TOKEN
        ANTHROPIC_API_KEY
        ANTHROPIC_MODEL
        ANTHROPIC_DEFAULT_OPUS_MODEL
        ANTHROPIC_DEFAULT_SONNET_MODEL
        ANTHROPIC_DEFAULT_HAIKU_MODEL
        CLAUDE_CODE_SUBAGENT_MODEL
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC
        API_TIMEOUT_MS
    )
    # Only forward env vars if no provider was set (avoid overriding provider config)
    if [ -z "${PROVIDER:-}" ]; then
        for var in "${api_vars[@]}"; do
            if [ -n "${!var:-}" ]; then
                SESSION_ENV_ARGS+=("$var=${!var}")
            fi
        done
    fi
}

# Start user isolation session
start_user_session() {
    local continue_flag="$1"
    _build_session_env
    sudo -u "$WORKER_USER" env "${SESSION_ENV_ARGS[@]}" bash -c "cd && source ~/.bashrc && cd '$WORKER_PROJECT' && $CLAUDE_BIN --dangerously-skip-permissions $continue_flag"
}

# Start namespace isolation session (firejail)
start_namespace_session() {
    local continue_flag="$1"
    _build_session_env

    # Enhanced: Add firejail namespace isolation
    local network_flag=""
    [ "$ALLOW_NETWORK" = false ] && network_flag="--net=none"

    # Docker support
    local docker_flags="--noroot"
    if [ "$ALLOW_DOCKER" = true ]; then
        # Docker access requires disabling User Namespace (--noroot) to preserve group permissions
        # and ensuring the socket is accessible
        docker_flags="--noblacklist=/var/run/docker.sock --noblacklist=/run/docker.sock"
    fi

    # Build firejail --env flags to explicitly pass env vars through the sandbox
    # (firejail may not inherit parent environment depending on version/config)
    local firejail_env_flags=""
    for env_entry in "${SESSION_ENV_ARGS[@]}"; do
        firejail_env_flags+=" --env=${env_entry}"
    done

    sudo -u "$WORKER_USER" bash -c "cd && source ~/.bashrc && cd '$WORKER_PROJECT' && firejail --quiet --noprofile --allusers --read-only=/home/linuxbrew $network_flag --private-dev --private-tmp $docker_flags --caps.drop=all --seccomp --deterministic-shutdown $firejail_env_flags -- $CLAUDE_BIN --dangerously-skip-permissions $continue_flag"
}

# Start shell session (user isolation, no Claude)
start_user_shell() {
    _build_session_env
    log_info "Starting shell as $WORKER_USER..."
    sudo -u "$WORKER_USER" env "${SESSION_ENV_ARGS[@]}" bash -c "cd && source ~/.bashrc && cd '$WORKER_PROJECT' && exec bash -l"
}

# Start shell session (namespace isolation, no Claude)
start_namespace_shell() {
    _build_session_env

    local network_flag=""
    [ "$ALLOW_NETWORK" = false ] && network_flag="--net=none"

    local docker_flags="--noroot"
    if [ "$ALLOW_DOCKER" = true ]; then
        docker_flags="--noblacklist=/var/run/docker.sock --noblacklist=/run/docker.sock"
    fi

    # Build firejail --env flags to explicitly pass env vars through the sandbox
    local firejail_env_flags=""
    for env_entry in "${SESSION_ENV_ARGS[@]}"; do
        firejail_env_flags+=" --env=${env_entry}"
    done

    log_info "Starting shell in firejail namespace..."
    sudo -u "$WORKER_USER" bash -c "cd && source ~/.bashrc && cd '$WORKER_PROJECT' && firejail --quiet --noprofile --allusers --read-only=/home/linuxbrew $network_flag --private-dev --private-tmp $docker_flags --caps.drop=all --seccomp --deterministic-shutdown $firejail_env_flags -- bash -l"
}
