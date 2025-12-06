#!/bin/bash
# Launch somewm with logging to a file
# Usage: ./launch-somewm.sh [timeout_seconds] [startup_command]
# Examples:
#   ./launch-somewm.sh                    # Normal run, no timeout
#   ./launch-somewm.sh 5                  # Run with 5s timeout
#   ./launch-somewm.sh 10 "kitty"         # Run with 10s timeout and startup command

TIMEOUT=${1:-}  # Optional timeout in seconds
STARTUP_CMD=${2:-}  # Optional startup command

LOGFILE="/tmp/somewm-$(date +%Y%m%d-%H%M%S).log"

echo "Starting somewm... Logs will be written to: $LOGFILE"
echo "View logs with: tail -f $LOGFILE"

# Enable wlroots debug logging and capture both stdout and stderr
export WLR_DEBUG=1
export AWESOME_THEMES_PATH="$(pwd)/themes"

# Build the command
if [ -n "$STARTUP_CMD" ]; then
    CMD="./somewm -s '$STARTUP_CMD'"
else
    CMD="./somewm"
fi

# If timeout specified, run with timeout handling
if [ -n "$TIMEOUT" ]; then
    echo "Running with ${TIMEOUT}s timeout"

    # Launch in background
    eval "$CMD" 2>&1 | tee "$LOGFILE" &
    SOMEWM_PID=$!

    # Wait for timeout
    sleep "$TIMEOUT"

    # Kill it
    if kill -0 "$SOMEWM_PID" 2>/dev/null; then
        echo "Timeout reached - terminating somewm (PID $SOMEWM_PID)"
        kill -TERM "$SOMEWM_PID" 2>/dev/null
        sleep 2

        # Force kill if still running
        if kill -0 "$SOMEWM_PID" 2>/dev/null; then
            echo "Force killing somewm"
            kill -KILL "$SOMEWM_PID" 2>/dev/null
        fi
    fi

    # Nuclear option - ensure all somewm processes are dead
    pkill -9 somewm 2>/dev/null

    echo "somewm terminated - logs at $LOGFILE"
else
    # Normal run - no timeout
    eval "$CMD" 2>&1 | tee "$LOGFILE"
fi
