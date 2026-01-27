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

### MCP servers (Context7, etc.) and Node/NPM

Some MCP servers are started via `npx` (for example `@upstash/context7-mcp`). For these to work inside the worker user:

- Your project `.mcp.json` should use **portable commands** like `npx` (not absolute paths like `/home/user/.nvm/.../npx`).
- The worker environment must have **Node + npx available on `PATH`**.

Recommended setup for multi-user portability:

- Install Node in shared Linuxbrew (works well with `clsecure` since workers already `eval "$(brew shellenv)"`):
  - `sudo -H -u linuxbrew /home/linuxbrew/.linuxbrew/bin/brew install node`

Alternative options:

- Install system-wide Node: `sudo apt-get install -y nodejs npm`
- Or install Node per-worker using the `setup_script` hook (e.g. using `nvm` inside the worker user’s `$HOME`)

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

## Development

**clsecure** uses a modular architecture for maintainability:

```
clsecure/
├── clsecure          # Built single-file (for distribution)
├── clsecure-src      # Modular main script (for development)
├── lib/              # Module library
│   ├── vars.sh      # Variable initialization
│   ├── logging.sh   # Logging functions
│   ├── lock.sh      # Lock management
│   ├── config.sh    # Configuration loading
│   ├── worker.sh    # Worker user management
│   ├── git.sh       # Git operations
│   ├── sanitize.sh  # Path sanitization
│   ├── deps.sh      # Dependency installation
│   ├── isolation.sh # Isolation execution
│   └── sync.sh      # Sync-back logic
└── build.sh         # Build script (generates clsecure from modules)
```

### Development Workflow

1. **Edit modules:** Modify `clsecure-src` and files in `lib/`
2. **Rebuild:** Run `./build.sh` to regenerate `clsecure`
3. **Test:** Run `./run_tests.sh` to execute unit tests
4. **Commit:** Pre-commit hook verifies build consistency

### Running Tests

```bash
# Install bats (test framework)
sudo apt install bats  # Ubuntu/Debian
brew install bats-core  # macOS

# Run all tests
./run_tests.sh
```

### Building

```bash
# Rebuild clsecure from modules
./build.sh
```

The build script concatenates all modules into a single-file `clsecure` for distribution, maintaining backwards compatibility.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

### Development Guidelines

- Follow bash best practices (`set -euo pipefail`)
- Use the logging functions (`log_info`, `log_warn`, etc.)
- Keep modules focused and under 300 lines
- Add tests for new functionality
- Run `./build.sh` before committing

## License

[MIT](LICENSE)
