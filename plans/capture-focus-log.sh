#!/bin/bash
# Auto-capture somewm focus debug logs
# Usage: Add to your session startup or run manually
#
# This script monitors the somewm journal for [FOCUS] entries.

LOGDIR="$HOME/.local/share/somewm/debug-logs"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/focus-$(date +%Y%m%d-%H%M%S).log"

echo "=== somewm Focus Debug Log ===" > "$LOGFILE"
echo "Started: $(date)" >> "$LOGFILE"
echo "Binary: $(readlink -f /proc/$(pgrep -x somewm)/exe 2>/dev/null || echo 'unknown')" >> "$LOGFILE"
echo "================================" >> "$LOGFILE"
echo "" >> "$LOGFILE"

echo "Capturing focus logs to: $LOGFILE"
echo "Press Ctrl+C to stop"

# Follow journalctl for somewm process, filtering for focus events
journalctl --user -f -t somewm 2>/dev/null | grep --line-buffered "\[FOCUS\]\|\[MAPNOTIFY\]\|\[FOCUS-API\]\|\[FOCUS-ACTIVATE\]\|\[FOCUS-ENTER\]\|\[SOMEWM-DEBUG\]" >> "$LOGFILE" &
JOURNAL_PID=$!

# Also check if running from TTY (logs go to stderr -> tty)
# In that case, we need the -d flag log output
if [ -f /tmp/somewm-debug.log ]; then
    tail -f /tmp/somewm-debug.log 2>/dev/null | grep --line-buffered "\[FOCUS\]\|\[MAPNOTIFY\]\|\[FOCUS-API\]\|\[FOCUS-ACTIVATE\]\|\[FOCUS-ENTER\]\|\[SOMEWM-DEBUG\]" >> "$LOGFILE" &
    TAIL_PID=$!
fi

cleanup() {
    kill $JOURNAL_PID $TAIL_PID 2>/dev/null
    echo "" >> "$LOGFILE"
    echo "=== Stopped: $(date) ===" >> "$LOGFILE"
    echo "Log saved to: $LOGFILE"
}
trap cleanup EXIT

wait
