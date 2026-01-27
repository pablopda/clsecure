#!/bin/bash
# lib/sanitize.sh
# 
# Path sanitization for MCP and Claude config files
# 
# Dependencies: lib/logging.sh, lib/worker.sh, lib/vars.sh
# Exports: sanitize_mcp_config, sanitize_worker_claude_home_paths, check_worker_mcp_runtime
# 
# Usage:
#   source lib/sanitize.sh
#   sanitize_mcp_config

# Sanitize project-local MCP config so it works under worker users.
# Claude often stores absolute tool paths (e.g. /home/<user>/.nvm/.../npx) in `.mcp.json`,
# which breaks when the repo is copied to a different Linux user/home.
sanitize_mcp_config() {
    local mcp_file="$WORKER_PROJECT/.mcp.json"

    [ -f "$mcp_file" ] || return 0

    if ! command -v python3 &>/dev/null; then
        log_warn "Found .mcp.json but python3 is unavailable; skipping MCP path sanitization."
        return 0
    fi

    log_step "Sanitizing MCP config paths (.mcp.json)..."

    # Run as the worker user so ownership/permissions stay correct.
    # Wrap in error handling so failures don't crash the main script
    sudo -u "$WORKER_USER" WORKER_PROJECT="$WORKER_PROJECT" python3 - <<'PY' || true
import json
import os
import pathlib
import sys

try:
    mcp_path = pathlib.Path(os.environ["WORKER_PROJECT"]) / ".mcp.json"

    try:
        raw = mcp_path.read_text(encoding="utf-8")
    except FileNotFoundError:
        sys.exit(0)

    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        # Don't brick the user's file; just leave it untouched.
        sys.exit(0)

    servers = data.get("mcpServers")
    if not isinstance(servers, dict):
        sys.exit(0)

    def should_portabilize(cmd: str) -> bool:
        if not cmd:
            return False
        # Common "copied-from-host-user" patterns. We keep this conservative to avoid
        # breaking legitimate custom absolute binaries.
        if "/.nvm/" in cmd:
            return True
        if "/.asdf/" in cmd:
            return True
        if "/.volta/" in cmd:
            return True
        return False

    portable_basenames = {"npx", "node", "python", "python3", "uvx", "pipx"}
    changed = False

    for name, cfg in servers.items():
        if not isinstance(cfg, dict):
            continue
        cmd = cfg.get("command")
        if not isinstance(cmd, str):
            continue

        base = os.path.basename(cmd)
        if base in portable_basenames and (os.path.isabs(cmd) and should_portabilize(cmd)):
            cfg["command"] = base
            changed = True

    if not changed:
        sys.exit(0)

    try:
        mcp_path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    except (OSError, PermissionError, IOError):
        # Best-effort operation: if write fails (permission denied, disk full, etc.), 
        # exit successfully so the main script continues
        sys.exit(0)
    except Exception:
        # Catch any other unexpected errors
        sys.exit(0)
except Exception:
    # Top-level exception handler: catch any unexpected errors and exit successfully
    # This is a best-effort operation and should not crash the main script
    sys.exit(0)
PY
}

check_worker_mcp_runtime() {
    # MCP servers that run via npx need node+npx available to the worker user.
    if sudo -u "$WORKER_USER" bash -c "source '$WORKER_HOME/.bashrc' >/dev/null 2>&1; command -v npx >/dev/null 2>&1"; then
        return 0
    fi

    log_warn "Worker cannot find 'npx' on PATH. MCP servers that use npx will fail to start."
    log_info "Fix options (pick one):"
    log_info "  - Install Node globally (recommended with this setup): sudo -H -u linuxbrew /home/linuxbrew/.linuxbrew/bin/brew install node"
    log_info "  - Or install Node system-wide: sudo apt-get install -y nodejs npm"
    log_info "  - Or use clsecure's setup_script hook to install Node inside the worker user (e.g. via nvm in \$HOME)"
}

sanitize_worker_claude_home_paths() {
    # After copying ~/.claude from the host user to the worker, rewrite any absolute
    # host-home paths (e.g. /home/arkat/...) to the worker home. Some Claude settings,
    # including skill/config locations, can be stored as absolute paths.
    local claude_dir="$WORKER_HOME/.claude"
    local host_home="$HOME"
    local worker_home="$WORKER_HOME"

    [ -d "$claude_dir" ] || return 0

    if ! command -v python3 &>/dev/null; then
        log_warn "python3 unavailable; skipping Claude config path sanitization."
        return 0
    fi

    log_step "Sanitizing Claude config paths (~/.claude)..."

    # Wrap in error handling so failures don't crash the main script
    sudo -u "$WORKER_USER" HOST_HOME="$host_home" WORKER_HOME="$worker_home" CLAUDE_DIR="$claude_dir" python3 - <<'PY' || true
import os
import pathlib
import re
import sys

try:
    host_home = os.environ["HOST_HOME"]
    worker_home = os.environ["WORKER_HOME"]
    claude_dir = pathlib.Path(os.environ["CLAUDE_DIR"])

    def is_probably_text(b: bytes) -> bool:
        # NUL byte is a strong signal of binary
        return b.find(b"\x00") == -1

    def replace_path_safely(text: str, old_path: str, new_path: str) -> str:
        """Replace old_path with new_path only when it appears as a standalone file path.
        
        This avoids false positives in URLs, usernames, or other non-path contexts.
        Matches when old_path is:
        - At start of string or preceded by: whitespace, quotes, =, :, [, {
        - Followed by: / (path continuation), end of string, whitespace, quotes, comma, }, ]
        """
        # Escape special regex characters in the path
        escaped_old = re.escape(old_path)
        # Pattern: match path when it appears in path-like context
        # Preceded by start/whitespace/quotes/operators, followed by / or end/whitespace/punctuation
        pattern = r'(^|[\s"\'=:\[{])' + escaped_old + r'(/|$|[\s"\'},])'
        
        def replacer(match):
            prefix = match.group(1)
            suffix = match.group(2)
            # If suffix is /, preserve it; otherwise it's end/whitespace/punctuation (preserve as-is)
            if suffix == '/':
                return prefix + new_path + '/'
            elif suffix == '':
                # End of string
                return prefix + new_path
            else:
                # Whitespace or punctuation - preserve it
                return prefix + new_path + suffix
        
        return re.sub(pattern, replacer, text)

    # Use a list to track changed files count (mutable object for nested functions)
    changed_files = [0]

    # Use iterdir() and manual recursion instead of rglob() to avoid following symlinks
    # rglob() follows symlinks by default, which can cause permission errors
    def process_directory(dir_path):
        """Recursively process directory, skipping symlinks."""
        try:
            for item in dir_path.iterdir():
                # Skip symlinks entirely to avoid following them outside worker directory
                if item.is_symlink():
                    continue
                
                if item.is_dir():
                    # Recursively process subdirectories
                    process_directory(item)
                elif item.is_file():
                    # Process the file (error handling is inside process_file)
                    process_file(item)
        except (PermissionError, OSError):
            # Skip directories we can't access
            return
    
    def process_file(p):
        """Process a single file for path sanitization."""
        try:
            st = p.stat()
        except (FileNotFoundError, PermissionError, OSError):
            return

        # Avoid large/unexpected files
        if st.st_size > 1024 * 1024:
            return

        try:
            raw = p.read_bytes()
        except (OSError, FileNotFoundError, PermissionError):
            return

        if not is_probably_text(raw):
            return

        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError:
            return

        if host_home not in text:
            return

        new_text = replace_path_safely(text, host_home, worker_home)
        if new_text != text:
            try:
                p.write_text(new_text, encoding="utf-8")
                changed_files[0] += 1
            except (OSError, PermissionError, IOError):
                # Best-effort operation: skip this file but continue processing others
                return
            except Exception:
                # Catch any other unexpected errors for this file
                return
    
    # Start processing from the claude directory
    process_directory(claude_dir)

    # Always exit successfully - this is a best-effort operation
    sys.exit(0)
except Exception:
    # Top-level exception handler: catch any unexpected errors and exit successfully
    # This is a best-effort operation and should not crash the main script
    sys.exit(0)
PY
}
