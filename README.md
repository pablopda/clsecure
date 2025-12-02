# clsecure

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/platform-Linux-blue.svg)](https://www.linux.org/)
[![Shell](https://img.shields.io/badge/shell-bash-green.svg)](https://www.gnu.org/software/bash/)

Run [Claude Code](https://docs.anthropic.com/en/docs/claude-code) in an isolated environment using dedicated Linux users with optional namespace/container isolation.

## Why?

Claude Code is powerful but can execute arbitrary code on your machine. **clsecure** provides defense-in-depth:

- 🔒 **Dedicated user per project** - File access isolated from your main user
- 🌐 **Network isolation** - Prevent data exfiltration (optional)
- 📦 **Namespace sandboxing** - Process, mount, and IPC isolation
- 🐳 **Container option** - Maximum isolation with podman

## Installation

```bash
# Download and install
curl -fsSL https://raw.githubusercontent.com/pablopda/clsecure/main/clsecure -o clsecure
chmod +x clsecure
sudo install -m 755 clsecure /usr/local/bin/

# Install dependencies (for namespace mode)
sudo apt install firejail
```

## Quick Start

```bash
# Navigate to your git project
cd ~/projects/my-app

# Run Claude Code in isolation
clsecure
```

## Isolation Modes

| Mode | Security | Requirements | Description |
|------|----------|--------------|-------------|
| `user` | ⭐⭐⭐ | sudo | Dedicated Linux user per project |
| `namespace` | ⭐⭐⭐⭐ | firejail | User + firejail sandbox **(default)** |
| `container` | ⭐⭐⭐⭐⭐ | podman | User + rootless container |

## Usage

```bash
clsecure [OPTIONS]

Options:
  --help, -h        Show help
  --list, -l        List worker users
  --cleanup         Remove worker users
  --mode MODE       user | namespace (default) | container
  --allow-network   Allow network access
  --allow-docker    Allow Docker access
  --info            Show isolation details
```

## Examples

```bash
# Default (namespace isolation)
clsecure

# With network access (for git push, npm install)
clsecure --allow-network

# Maximum security (container isolation)
clsecure --mode container

# Simple isolation (user only)
clsecure --mode user

# List all worker users
clsecure --list

# Clean up workers
clsecure --cleanup
```

## How It Works

```
┌─────────────────────────────────────────────────────────┐
│  Your Machine                                           │
│  ┌───────────────────────────────────────────────────┐  │
│  │  claude-worker-myproject (dedicated user)         │  │
│  │  ┌─────────────────────────────────────────────┐  │  │
│  │  │  Firejail Namespace (optional)              │  │  │
│  │  │  ┌─────────────────────────────────────┐    │  │  │
│  │  │  │  Claude Code                        │    │  │  │
│  │  │  │  - Isolated filesystem              │    │  │  │
│  │  │  │  - No network (unless allowed)      │    │  │  │
│  │  │  │  - Restricted capabilities          │    │  │  │
│  │  │  └─────────────────────────────────────┘    │  │  │
│  │  └─────────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

1. Creates a dedicated Linux user: `claude-worker-<project>`
2. Clones your git repo (with submodules) to the worker's home
3. Syncs uncommitted changes
4. Runs Claude Code as that user with restricted permissions
5. After session: syncs changes back and offers to commit

## Requirements

- Linux (Ubuntu/Debian/Fedora/Arch)
- `git`, `rsync`, `sudo`
- For namespace mode: `firejail`
- For container mode: `podman`

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

[MIT](LICENSE)
