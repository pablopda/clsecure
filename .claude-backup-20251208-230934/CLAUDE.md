# CLAUDE.md - Project Instructions for Claude Code

## Project Overview

**clsecure** is a bash script that runs Claude Code in an isolated environment using dedicated Linux users and optional namespace/container isolation.

## Key Files

- `clsecure` - Main script (production)
- `clsecure-enhanced` - Enhanced version with namespace isolation
- `UPGRADE-GUIDE.md` - Instructions for upgrading isolation modes

## Architecture

The script creates a dedicated Linux user (`claude-worker-<project>`) per project, clones the git repository to that user's home directory, and runs Claude Code as that user with restricted permissions.

### Isolation Modes

1. **user** - Basic user isolation (security: 6/10)
2. **namespace** - User + firejail namespace (security: 8/10) - RECOMMENDED
3. **container** - User + podman rootless container (security: 9/10)

## Development Guidelines

### Shell Script Style

- Use `set -euo pipefail` at the start
- Use functions for reusable logic
- Use color-coded logging: `log_info`, `log_warn`, `log_error`, `log_step`, `log_security`
- Validate all user inputs
- Quote all variables: `"$VAR"` not `$VAR`

### Testing Changes

```bash
# Test in a safe directory first
cd /tmp/test-project
git init
clsecure --help

# Test isolation modes
clsecure --mode user
clsecure --mode namespace
```

### Common Tasks

```bash
# List worker users
clsecure --list

# Clean up workers
clsecure --cleanup

# Show isolation info
clsecure --info
```

## Important Notes

- Script must be run from a git repository
- Requires: git, rsync, sudo
- For namespace mode: firejail
- For container mode: podman
- Git submodules are cloned with `--recurse-submodules`

## Installation

```bash
sudo install -m 755 clsecure /usr/local/bin/
```

