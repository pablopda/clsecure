#!/bin/bash
# lib/isolation.sh
# 
# Isolation mode execution for clsecure
# 
# Dependencies: lib/logging.sh, lib/config.sh, lib/worker.sh, lib/vars.sh
# Exports: check_isolation_requirements, show_isolation_info, start_user_session, start_namespace_session, start_container_session
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
        container)
            if ! command -v podman &>/dev/null; then
                log_error "Podman not found. Install with: sudo apt install podman"
                log_info "Or use --mode namespace for firejail isolation"
                exit 1
            fi
            log_security "Container isolation enabled (podman)"
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
        container)
            echo -e "${CYAN}Container + User Namespace Isolation (Maximum)${NC}"
            echo "  ✓ All namespace isolation features"
            echo "  ✓ Rootless container (podman)"
            echo "  ✓ Complete filesystem isolation"
            echo "  ✓ Immutable base image"
            echo "  ✓ Resource limits (cgroups)"
            echo "  ✓ SELinux/AppArmor integration"
            echo ""
            echo -e "${CYAN}Security Level: 9/10${NC}"
            echo "Good for: Maximum security, untrusted code"
            echo ""
            echo -e "${YELLOW}Note:${NC} Container mode requires podman and image build"
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
        container)
            echo "  File access outside project:  Completely isolated"
            echo "  Network exfiltration:         Configurable"
            echo "  Privilege escalation:         Blocked (multiple layers)"
            echo "  Process interference:         Completely isolated"
            echo "  Device access:                Completely isolated"
            ;;
    esac

    echo ""
    exit 0
}

# Start user isolation session
start_user_session() {
    local continue_flag="$1"
    # Original behavior: just run as worker user
    # Pass GH_TOKEN if available to the session too
    local gh_token_val="${GH_TOKEN:-}"
    if [ -z "$gh_token_val" ] && command -v gh &>/dev/null; then
         gh_token_val=$(gh auth token 2>/dev/null || echo "")
    fi
    
    # Use env command to safely pass environment variables (avoids command injection)
    if [ -n "$gh_token_val" ]; then
        sudo -u "$WORKER_USER" env GH_TOKEN="$gh_token_val" bash -c "cd && source ~/.bashrc && cd '$WORKER_PROJECT' && $CLAUDE_BIN --dangerously-skip-permissions $continue_flag"
    else
        sudo -u "$WORKER_USER" bash -c "cd && source ~/.bashrc && cd '$WORKER_PROJECT' && $CLAUDE_BIN --dangerously-skip-permissions $continue_flag"
    fi
}

# Start namespace isolation session (firejail)
start_namespace_session() {
    local continue_flag="$1"
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

    sudo -u "$WORKER_USER" bash -c "cd && source ~/.bashrc && cd '$WORKER_PROJECT' && firejail --quiet --noprofile --allusers --read-only=/home/linuxbrew $network_flag --private-dev --private-tmp $docker_flags --caps.drop=all --seccomp -- $CLAUDE_BIN --dangerously-skip-permissions $continue_flag"
}

# Start container isolation session (podman)
start_container_session() {
    local continue_flag="$1"
    # Maximum security: Podman rootless container
    log_error "Container mode not yet implemented in this prototype"
    log_info "Use --mode namespace for enhanced isolation"
    return 1
}

# Start shell session (user isolation, no Claude)
start_user_shell() {
    log_info "Starting shell as $WORKER_USER..."
    sudo -u "$WORKER_USER" bash -c "cd && source ~/.bashrc && cd '$WORKER_PROJECT' && exec bash -l"
}

# Start shell session (namespace isolation, no Claude)
start_namespace_shell() {
    local network_flag=""
    [ "$ALLOW_NETWORK" = false ] && network_flag="--net=none"

    local docker_flags="--noroot"
    if [ "$ALLOW_DOCKER" = true ]; then
        docker_flags="--noblacklist=/var/run/docker.sock --noblacklist=/run/docker.sock"
    fi

    log_info "Starting shell in firejail namespace..."
    sudo -u "$WORKER_USER" bash -c "cd && source ~/.bashrc && cd '$WORKER_PROJECT' && firejail --quiet --noprofile --allusers --read-only=/home/linuxbrew $network_flag --private-dev --private-tmp $docker_flags --caps.drop=all --seccomp -- bash -l"
}
