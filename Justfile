# Justfile for clsecure
# Run `just` to see available commands

# Default: show help
default:
    @just --list

# Build single-file distribution
build:
    ./build.sh

# Run tests
test:
    ./run_tests.sh

# Build and run tests
check: build test

# Install to /usr/local/bin
install: build
    sudo install -m 755 clsecure /usr/local/bin/

# Syntax check only
lint:
    bash -n clsecure
    bash -n clsecure-src
    @for f in lib/*.sh; do bash -n "$f" || exit 1; done
    @echo "All syntax checks passed"

# Show help
help:
    ./clsecure --help

# List worker users
list:
    ./clsecure --list

# Clean up all worker users (interactive)
cleanup:
    ./clsecure --cleanup

# Clean up build artifacts
clean:
    @echo "No build artifacts to clean (single-file script)"

# Development: rebuild and install
dev: build install
    @echo "Installed to /usr/local/bin/clsecure"

# Run clsecure with shell mode (for debugging)
shell:
    ./clsecure --shell --skip-setup

# Show current configuration
config:
    ./clsecure --config

# Show isolation info
info:
    ./clsecure --info

# Run a named session
session name:
    ./clsecure --session {{name}}

# Run shell mode with a named session
shell-session name:
    ./clsecure --shell --skip-setup --session {{name}}
