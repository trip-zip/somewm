#!/usr/bin/env bash
#
# Memory trend analysis runner.
# Starts a headless compositor, installs the memory sampler, drives load
# patterns, then collects results.
#
# Usage: tests/bench/bench-memory-runner.sh
# Or:    make bench-memory

set -e

export LC_NUMERIC=C

SOMEWM="${SOMEWM:-./somewm}"
SOMEWM_CLIENT="${SOMEWM_CLIENT:-./somewm-client}"
DURATION=${DURATION:-120}  # Total duration in seconds
PHASE_DURATION=$((DURATION / 4))

cd "$(dirname "$0")/../.."
ROOT_DIR="$PWD"

TMP_DIR=$(mktemp -d)
LOG="$TMP_DIR/somewm.log"
TEST_RUNTIME_DIR="$TMP_DIR/runtime"
mkdir -p "$TEST_RUNTIME_DIR"
chmod 700 "$TEST_RUNTIME_DIR"

TEST_CONFIG_DIR="$TMP_DIR/config/somewm"
mkdir -p "$TEST_CONFIG_DIR"
cat > "$TEST_CONFIG_DIR/rc.lua" << 'RCEOF'
local awful = require("awful")
awful.rules.rules = {
    { rule = { }, properties = { focus = true } },
}
screen.connect_signal("request::desktop_decoration", function(s)
    awful.tag({ "1", "2", "3", "4", "5", "6", "7", "8", "9" }, s, awful.layout.suit.tile)
end)
RCEOF

export WLR_BACKENDS=headless
export WLR_RENDERER=pixman
export WLR_WL_OUTPUTS=1
export NO_AT_BRIDGE=1
export XDG_RUNTIME_DIR="$TEST_RUNTIME_DIR"
export XDG_CONFIG_HOME="$TMP_DIR/config"
export LUA_PATH="$ROOT_DIR/lua/?.lua;$ROOT_DIR/lua/?/init.lua;;"

cleanup() {
    if [ -n "$SOMEWM_PID" ] && kill -0 "$SOMEWM_PID" 2>/dev/null; then
        kill "$SOMEWM_PID" 2>/dev/null
        wait "$SOMEWM_PID" 2>/dev/null || true
    fi
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# Start compositor
"$SOMEWM" > "$LOG" 2>&1 &
SOMEWM_PID=$!

# Wait for IPC
for i in $(seq 1 30); do
    SOCKET=$(ls "$TEST_RUNTIME_DIR"/wayland-* 2>/dev/null | head -1)
    if [ -n "$SOCKET" ]; then break; fi
    sleep 0.1
done
export WAYLAND_DISPLAY=$(basename "$SOCKET")

for i in $(seq 1 20); do
    if "$SOMEWM_CLIENT" eval "return 'ready'" 2>/dev/null | grep -q ready; then break; fi
    sleep 0.1
done

echo "=== Memory Trend Analysis (${DURATION}s) ==="
echo ""

# Start memory sampler
"$SOMEWM_CLIENT" eval "return dofile('tests/bench/bench-memory-trend.lua')" 2>/dev/null
echo ""

# Phase 1: Idle
echo "Phase 1/${PHASE_DURATION}s: Idle..."
sleep "$PHASE_DURATION"

# Phase 2: Tag switching churn
echo "Phase 2/${PHASE_DURATION}s: Tag switching..."
for i in $(seq 1 $((PHASE_DURATION * 10))); do
    "$SOMEWM_CLIENT" eval "screen[1].tags[($i % 9) + 1]:view_only()" 2>/dev/null || true
    sleep 0.1
done

# Phase 3: Property churn (if clients exist)
echo "Phase 3/${PHASE_DURATION}s: Property churn..."
for i in $(seq 1 $((PHASE_DURATION * 5))); do
    "$SOMEWM_CLIENT" eval "
        for _, c in ipairs(client.get()) do
            c.ontop = not c.ontop
        end
    " 2>/dev/null || true
    sleep 0.2
done

# Phase 4: Idle recovery
echo "Phase 4/${PHASE_DURATION}s: Idle recovery..."
sleep "$PHASE_DURATION"

# Collect results
echo ""
echo "Collecting results..."
RESULT=$("$SOMEWM_CLIENT" eval "return bench_memory_stop()" 2>/dev/null)
echo "$RESULT"

# Save to file if requested
if [ -n "$OUTPUT" ]; then
    echo "$RESULT" > "$OUTPUT"
    echo "Saved to: $OUTPUT"
fi
