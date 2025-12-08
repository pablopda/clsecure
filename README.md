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

## Configuration & Custom Setup

You can configure persistent settings and custom setup scripts in `~/.config/clsecure/config`.

### Configuration File

Create `~/.config/clsecure/config`:

```ini
# ~/.config/clsecure/config

# Default isolation mode (user, namespace, container)
mode = namespace

# Allow network access by default
network = true

# Path to a custom setup script (executed inside the worker environment)
setup_script = /home/user/.config/clsecure/install_private_tools.sh
```

### Custom Setup Script (Private Tools)

You can use the `setup_script` hook to install private tools or configure the environment. The script runs as the worker user inside the isolated environment.

**Key Feature:** If you have `gh` (GitHub CLI) installed and authenticated on your host, `clsecure` will inject your `GH_TOKEN` into the worker environment during the setup script execution. This allows you to install private tools without exposing credentials in the public codebase.

**Example: `install_private_tools.sh`**

```bash
#!/bin/bash
# ~/.config/clsecure/install_private_tools.sh

# Install a private tool from GitHub using the injected GH_TOKEN
if command -v gh &>/dev/null && [ -n "$GH_TOKEN" ]; then
    echo "Installing private tools..."
    # Example: Install a python script from a private repo
    # python3 <(gh api repos/my-org/my-private-tool/contents/install.py --jq '.content' | base64 -d)
else
    echo "Skipping private install (GH_TOKEN missing)"
fi
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
