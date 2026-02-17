#!/bin/bash
# Wrapper to start somewm with debug logging captured to file
# Usage: Replace your normal somewm start command with this script
#
# Example in .bash_profile or session starter:
#   exec ~/git/github/somewm/plans/somewm-debug-wrapper.sh
#
# Or if you use a display manager, you can create a .desktop entry.

LOGDIR="$HOME/.local/share/somewm/debug-logs"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/session-$(date +%Y%m%d-%H%M%S).log"

echo "=== somewm Debug Session ===" > "$LOGFILE"
echo "Started: $(date)" >> "$LOGFILE"
echo "================================" >> "$LOGFILE"

# Start somewm with debug logging, capture stderr to log file
# The -d flag enables WLR_DEBUG level logging
exec somewm -d 2>> "$LOGFILE"
