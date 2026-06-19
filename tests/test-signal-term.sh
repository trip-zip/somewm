#!/usr/bin/env bash
#
# Regression test: somewm must terminate on SIGTERM (issue 613).
#
# Before the fix, the SIGINT/SIGTERM handler called wl_display_terminate(),
# which is a no-op because the primary loop is g_main_loop_run(), not
# wl_display_run(). So `kill <pid>` (SIGTERM) did nothing and only SIGKILL
# worked. This starts a headless somewm, sends SIGTERM only, and asserts the
# process exits on its own with no SIGKILL fallback.
#
# It cannot be a Lua/IPC integration test: terminating the compositor would
# kill the test runner, so this is a process-level test instead.
#
# Usage: ./tests/test-signal-term.sh [path-to-somewm-binary]

set -u

SOMEWM_ARG="${1:-./build-test/somewm}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ ! -x "$SOMEWM_ARG" ]; then
    echo "Error: somewm binary not found at $SOMEWM_ARG" >&2
    echo "Run 'make build-test' first" >&2
    exit 1
fi
# Resolve to an absolute path so we can spawn it after isolating the environment.
SOMEWM="$(cd "$(dirname "$SOMEWM_ARG")" && pwd)/$(basename "$SOMEWM_ARG")"

START_TIMEOUT=15   # seconds to wait for the compositor to come up
TERM_TIMEOUT=5     # seconds SIGTERM has to work before we force-kill

# Isolated, headless environment so the test never touches a real session.
TMP_DIR="$(mktemp -d)"
RUNTIME_DIR="$TMP_DIR/runtime"
mkdir -p "$RUNTIME_DIR"
chmod 700 "$RUNTIME_DIR"
CONFIG_DIR="$TMP_DIR/config/somewm"
mkdir -p "$CONFIG_DIR"
cp "$ROOT_DIR/tests/rc.lua" "$CONFIG_DIR/rc.lua"

export WLR_BACKENDS=headless
export WLR_RENDERER=pixman
export WLR_WL_OUTPUTS=1
export NO_AT_BRIDGE=1
export XDG_RUNTIME_DIR="$RUNTIME_DIR"
export XDG_CONFIG_HOME="$TMP_DIR/config"
export LUA_PATH="$ROOT_DIR/lua/?.lua;$ROOT_DIR/lua/?/init.lua;$ROOT_DIR/tests/?.lua;;"
# Force the headless backend: a stale DISPLAY/WAYLAND_DISPLAY can make wlroots
# pick the wrong backend.
unset DISPLAY WAYLAND_DISPLAY SOMEWM_SOCKET

SOCKET="$XDG_RUNTIME_DIR/somewm-socket"
LOG="$TMP_DIR/somewm.log"

SOMEWM_PID=""
cleanup() {
    [ -n "$SOMEWM_PID" ] && kill -KILL "$SOMEWM_PID" 2>/dev/null
    rm -rf "$TMP_DIR" 2>/dev/null
    return 0
}
trap cleanup EXIT INT TERM

fail() {
    echo "--- FAIL: $1"
    echo "Last 30 lines of somewm log:"
    tail -30 "$LOG" 2>/dev/null | sed 's/^/    /'
    exit 1
}

# Start the compositor directly (no `timeout` wrapper: we send the signal, and
# $! must be somewm itself, not a wrapper process).
"$SOMEWM" >"$LOG" 2>&1 &
SOMEWM_PID=$!

# Wait for startup: the IPC socket appears once the main loop is serving.
count=0
max=$(( START_TIMEOUT * 10 ))
while [ ! -S "$SOCKET" ] && [ "$count" -lt "$max" ]; do
    if ! kill -0 "$SOMEWM_PID" 2>/dev/null; then
        fail "somewm exited during startup"
    fi
    sleep 0.1
    count=$(( count + 1 ))
done
[ -S "$SOCKET" ] || fail "timed out waiting for somewm to start (${START_TIMEOUT}s)"

echo "--- INFO: somewm up (pid $SOMEWM_PID); sending SIGTERM"

# The assertion: SIGTERM alone must terminate it within TERM_TIMEOUT.
kill -TERM "$SOMEWM_PID"

# Watchdog: if SIGTERM is ignored, force-kill after the timeout and leave a marker.
( sleep "$TERM_TIMEOUT"; touch "$TMP_DIR/forced"; kill -KILL "$SOMEWM_PID" 2>/dev/null ) &
WATCHDOG_PID=$!

# Block until somewm exits (via SIGTERM, or the watchdog's SIGKILL).
STATUS=0
wait "$SOMEWM_PID" 2>/dev/null || STATUS=$?

# Stop the watchdog if it is still sleeping.
kill "$WATCHDOG_PID" 2>/dev/null || true
wait "$WATCHDOG_PID" 2>/dev/null || true

SOMEWM_PID=""   # reaped above; don't let cleanup() kill a recycled pid

if [ -f "$TMP_DIR/forced" ]; then
    fail "SIGTERM ignored: somewm did not exit within ${TERM_TIMEOUT}s (needed SIGKILL)"
fi

echo "--- PASS: somewm terminated on SIGTERM (exit status $STATUS)"
echo "PASS"
exit 0
