#!/bin/bash
# lib/logging.sh
# 
# Logging functions for clsecure
# 
# Dependencies: lib/vars.sh (for color variables)
# Exports: log_info, log_warn, log_error, log_step, log_security
# 
# Usage:
#   source lib/logging.sh
#   log_info "Message"

# Logging functions
# Note: These functions use color variables (GREEN, YELLOW, RED, BLUE, CYAN, NC)
# which are exported from lib/vars.sh. Ensure vars.sh is sourced before this module.
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }
log_security() { echo -e "${CYAN}[SECURITY]${NC} $1"; }
