#!/bin/bash
# run_tests.sh
# 
# Test runner for clsecure modules

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Check if bats is installed
if ! command -v bats &>/dev/null; then
    echo "Error: bats is not installed"
    echo ""
    echo "Install with:"
    echo "  Ubuntu/Debian: sudo apt install bats"
    echo "  macOS: brew install bats-core"
    echo "  Or: https://github.com/bats-core/bats-core#installation"
    exit 1
fi

# Run all test files
echo "Running clsecure module tests..."
echo ""

bats_version=$(bats --version 2>&1 | head -1)
echo "Using: $bats_version"
echo ""

# Run tests
if bats tests/*.bats; then
    echo ""
    echo "✅ All tests passed!"
    exit 0
else
    echo ""
    echo "❌ Some tests failed"
    exit 1
fi
