#!/bin/bash
# build.sh - Create single-file clsecure from modular structure
# 
# This script concatenates all modules and main script into a single file
# for distribution, while preserving functionality and variable initialization order.
#
# Usage: ./build.sh [output-file]
#   output-file: Output file path (default: clsecure)

set -euo pipefail

OUTPUT_FILE="${1:-clsecure}"
LIB_DIR="lib"
MAIN_SCRIPT_SRC="clsecure-src"  # Modular source file (sources from lib/)

if [ ! -d "$LIB_DIR" ]; then
    echo "Error: lib/ directory not found. Run from project root." >&2
    exit 1
fi

if [ ! -f "$MAIN_SCRIPT_SRC" ]; then
    echo "Error: $MAIN_SCRIPT_SRC not found. Run from project root." >&2
    echo "Expected modular source file: $MAIN_SCRIPT_SRC" >&2
    exit 1
fi

echo "Building single-file distribution: $OUTPUT_FILE"
echo "  Source: $MAIN_SCRIPT_SRC"
echo "  Modules: $LIB_DIR/"

# Step 1: Start with shebang and header
cat > "$OUTPUT_FILE" << 'HEADER'
#!/bin/bash

# clsecure - Enhanced isolation with User + Namespace (Firejail)
# This file is auto-generated from modular source. Do not edit directly.
# Source: https://github.com/pablopda/clsecure
# 
# To modify: Edit files in lib/ directory and run ./build.sh

set -euo pipefail
HEADER

# Step 2: Add module separator
cat >> "$OUTPUT_FILE" << 'SEPARATOR'

# ============================================================================
# Library Modules (auto-merged from lib/ directory)
# ============================================================================

SEPARATOR

# Step 3: Concatenate modules in dependency order
# Remove shebangs and add module headers
for module in vars.sh logging.sh lock.sh config.sh worker.sh git.sh sanitize.sh deps.sh isolation.sh sync.sh cleanup.sh; do
    if [ -f "$LIB_DIR/$module" ]; then
        echo "" >> "$OUTPUT_FILE"
        echo "# --- Module: $module ---" >> "$OUTPUT_FILE"
        # Remove shebang, keep everything else
        grep -v '^#!/bin/bash' "$LIB_DIR/$module" >> "$OUTPUT_FILE"
        echo "" >> "$OUTPUT_FILE"
    else
        echo "Warning: $LIB_DIR/$module not found, skipping..." >&2
    fi
done

# Step 4: Initialize variables (call init_clsecure_vars after modules are loaded)
cat >> "$OUTPUT_FILE" << 'INIT'

# Initialize all global variables
init_clsecure_vars

INIT

# Step 5: Add main script separator
cat >> "$OUTPUT_FILE" << 'SEPARATOR'

# ============================================================================
# Main Script (orchestration, CLI parsing, execution flow)
# ============================================================================

SEPARATOR

# Step 6: Extract main script logic
# Find the line where main script logic starts (after module sourcing)
# This is after the source statements and before actual execution
# 
# Strategy: Extract everything from main script EXCEPT:
# - Shebang (already added)
# - set -euo pipefail (already added)
# - Module source statements (modules already concatenated)
# - Variable initialization (already called above)

# Extract main script logic from clsecure-src
# The source file contains: SCRIPT_DIR setup, source statements, init calls, and main logic
# We need everything EXCEPT the source statements (modules already concatenated)
if grep -q "^SCRIPT_DIR=" "$MAIN_SCRIPT_SRC"; then
    # Extract from first non-module line onwards, but skip source statements and init calls
    # Track heredoc state to avoid filtering export statements inside heredocs
    awk "$(cat << 'AWKSCRIPT'
BEGIN {
    in_heredoc = 0
    heredoc_delim = ""
}
/^SCRIPT_DIR=/ { start=1 }
# Track heredoc start: look for << followed by a delimiter
start && /<</ {
    # Extract delimiter: find the word after << (handles << EOF, <<- EOF, << 'EOF', etc.)
    pos = index($0, "<<")
    if (pos > 0) {
        # Get substring after <<
        rest = substr($0, pos + 2)
        # Remove leading whitespace and optional dash
        gsub(/^[ \t-]+/, "", rest)
        # Extract first word (may be quoted)
        first_char = substr(rest, 1, 1)
        if (first_char == "\047" || first_char == "\042") {
            quote = first_char
            end = index(substr(rest, 2), quote)
            if (end > 0) {
                heredoc_delim = substr(rest, 2, end - 1)
            }
        } else {
            # Unquoted: take first word
            gsub(/[ \t].*$/, "", rest)
            heredoc_delim = rest
        }
        if (heredoc_delim ~ /^[A-Za-z_][A-Za-z0-9_]*$/) {
            in_heredoc = 1
        }
    }
}
# Track heredoc end: line contains only the delimiter (possibly with whitespace)
start && in_heredoc && heredoc_delim != "" {
    trimmed = $0
    gsub(/^[ \t]+/, "", trimmed)
    gsub(/[ \t]+$/, "", trimmed)
    if (trimmed == heredoc_delim) {
        in_heredoc = 0
        heredoc_delim = ""
    }
}
# Skip filters only apply when NOT in heredoc
start && !in_heredoc && /^source / { next }
start && !in_heredoc && /^init_clsecure_vars/ { next }
# Filter out export statements EXCEPT runtime exports (ORIGINAL_BRANCH, CLAUDE_BIN)
# These are needed by subshells and functions, unlike vars.sh exports which are handled during init
start && !in_heredoc && /^export / && !/export (ORIGINAL_BRANCH|CLAUDE_BIN)/ { next }
# Note: Don't filter out trap statements - they're needed early in the script
start { print }
AWKSCRIPT
)" "$MAIN_SCRIPT_SRC" >> "$OUTPUT_FILE"
    
    # Add trap handler at the end (after all initialization)
    echo "" >> "$OUTPUT_FILE"
    echo "# Register trap handler after all initialization" >> "$OUTPUT_FILE"
    echo "trap cleanup_on_exit EXIT" >> "$OUTPUT_FILE"
else
    echo "Error: Could not find SCRIPT_DIR in $MAIN_SCRIPT_SRC" >&2
    echo "Expected modular source file with SCRIPT_DIR setup" >&2
    exit 1
fi

# Step 7: Make executable
chmod +x "$OUTPUT_FILE"

echo "✓ Built: $OUTPUT_FILE"
echo "  Lines: $(wc -l < "$OUTPUT_FILE")"
echo ""
echo "To test:"
echo "  bash -n $OUTPUT_FILE  # Syntax check"
echo "  ./$OUTPUT_FILE --help  # Functional test"
