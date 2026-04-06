#!/usr/bin/env bash
#
# Benchmark runner for somewm signal dispatch profiling
#
# Modes:
#   HEADLESS=1: Run with headless backend (default for benchmarks)
#   HEADLESS=0: Run against the current compositor session
#
# Usage:
#   tests/bench/run-all.sh                    # Headless mode
#   HEADLESS=0 tests/bench/run-all.sh         # Against running session
#   tests/bench/run-all.sh bench-focus-cycle   # Single benchmark

set -e

export LC_NUMERIC=C

SOMEWM="${SOMEWM:-./somewm}"
SOMEWM_CLIENT="${SOMEWM_CLIENT:-./somewm-client}"
HEADLESS=${HEADLESS:-1}
RUNS=${RUNS:-5}

cd "$(dirname "$0")/../.."
ROOT_DIR="$PWD"

BENCH_DIR="$ROOT_DIR/tests/bench"

# Determine which benchmarks to run
if [ -n "$1" ]; then
    BENCHMARKS=("$BENCH_DIR/$1.lua")
else
    BENCHMARKS=("$BENCH_DIR"/bench-*.lua)
fi

# Validate benchmarks exist
for b in "${BENCHMARKS[@]}"; do
    if [ ! -f "$b" ]; then
        echo "Error: benchmark not found: $b" >&2
        exit 1
    fi
done

run_against_session() {
    # Run benchmarks against the currently running compositor
    echo "=== Running against live session ==="
    echo ""

    for bench in "${BENCHMARKS[@]}"; do
        name=$(basename "$bench" .lua)
        echo "--- $name (${RUNS} runs) ---"

        for run in $(seq 1 "$RUNS"); do
            echo "[run $run/$RUNS]"
            "$SOMEWM_CLIENT" eval "return dofile('$bench')"
            echo ""
        done
    done
}

run_headless() {
    # Start a headless compositor, spawn test clients, run benchmarks
    echo "=== Running in headless mode ==="
    echo ""

    TMP_DIR=$(mktemp -d)
    LOG="$TMP_DIR/somewm.log"
    TEST_RUNTIME_DIR="$TMP_DIR/runtime"
    mkdir -p "$TEST_RUNTIME_DIR"
    chmod 700 "$TEST_RUNTIME_DIR"

    # Create test config that spawns some windows
    TEST_CONFIG_DIR="$TMP_DIR/config/somewm"
    mkdir -p "$TEST_CONFIG_DIR"
    cat > "$TEST_CONFIG_DIR/rc.lua" << 'RCEOF'
local awful = require("awful")
local gears = require("gears")

-- Minimal config for benchmarking
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

    # Wait for socket
    SOCKET=""
    for i in $(seq 1 30); do
        SOCKET=$(ls "$TEST_RUNTIME_DIR"/wayland-* 2>/dev/null | head -1)
        if [ -n "$SOCKET" ]; then
            break
        fi
        sleep 0.1
    done

    if [ -z "$SOCKET" ]; then
        echo "Error: compositor did not start" >&2
        cat "$LOG" >&2
        exit 1
    fi

    export WAYLAND_DISPLAY=$(basename "$SOCKET")

    # Wait for IPC
    for i in $(seq 1 20); do
        if "$SOMEWM_CLIENT" eval "return 'ready'" 2>/dev/null | grep -q ready; then
            break
        fi
        sleep 0.1
    done

    echo "Compositor ready (PID $SOMEWM_PID)"
    echo ""

    # Run benchmarks
    for bench in "${BENCHMARKS[@]}"; do
        name=$(basename "$bench" .lua)
        echo "--- $name (${RUNS} runs) ---"

        for run in $(seq 1 "$RUNS"); do
            echo "[run $run/$RUNS]"
            "$SOMEWM_CLIENT" eval "return dofile('$bench')" || echo "FAILED"
            echo ""
        done
    done

    # Print frame stats at end
    "$SOMEWM_CLIENT" eval "
        if awesome.bench_stats then
            local s = awesome.bench_stats()
            print('=== frame timing ===')
            print(string.format('refresh_count: %d', s.refresh_count))
            print(string.format('refresh_avg_us: %.1f', s.refresh_avg_us))
            print(string.format('refresh_p99_us: %.1f', s.refresh_p99_us))
            print(string.format('refresh_max_us: %.1f', s.refresh_max_us))
        end
    " 2>/dev/null || true
}

if [ "$HEADLESS" = 1 ]; then
    run_headless
else
    run_against_session
fi
