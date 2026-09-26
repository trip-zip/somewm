#!/usr/bin/env bash
#
# A running compositor keeps its IPC socket when another instance starts at
# the same path. Both compositors use a private runtime directory.
#
# Usage: ./tests/test-ipc-socket-live-owner.sh [somewm] [somewm-client]

set -u

SOMEWM_ARG="${1:-./build-test/somewm}"
CLIENT_ARG="${2:-./build-test/somewm-client}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

for bin in "$SOMEWM_ARG" "$CLIENT_ARG"; do
    if [ ! -x "$bin" ]; then
        echo "Error: binary not found at $bin" >&2
        echo "Run 'make build-test' first" >&2
        exit 1
    fi
done
SOMEWM="$(cd "$(dirname "$SOMEWM_ARG")" && pwd)/$(basename "$SOMEWM_ARG")"
CLIENT="$(cd "$(dirname "$CLIENT_ARG")" && pwd)/$(basename "$CLIENT_ARG")"

START_TIMEOUT=15

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
unset DISPLAY WAYLAND_DISPLAY SOMEWM_SOCKET

SOCKET="$XDG_RUNTIME_DIR/somewm-socket"
LOG_A="$TMP_DIR/a.log"
LOG_B="$TMP_DIR/b.log"

PID_A=""
PID_B=""
cleanup() {
    [ -n "$PID_A" ] && kill -KILL "$PID_A" 2>/dev/null
    [ -n "$PID_B" ] && kill -KILL "$PID_B" 2>/dev/null
    rm -rf "$TMP_DIR" 2>/dev/null
    return 0
}
trap cleanup EXIT INT TERM

fail() {
    echo "--- FAIL: $1"
    echo "Last 20 lines of each log:"
    tail -20 "$LOG_A" 2>/dev/null | sed 's/^/  A: /'
    tail -20 "$LOG_B" 2>/dev/null | sed 's/^/  B: /'
    exit 1
}

"$SOMEWM" >"$LOG_A" 2>&1 &
PID_A=$!
count=0
max=$(( START_TIMEOUT * 10 ))
while [ ! -S "$SOCKET" ] && [ "$count" -lt "$max" ]; do
    kill -0 "$PID_A" 2>/dev/null || fail "A exited during startup"
    sleep 0.1
    count=$(( count + 1 ))
done
[ -S "$SOCKET" ] || fail "timed out waiting for A's socket"
INODE_A="$(stat -c %i "$SOCKET")"
echo "--- INFO: A up (pid $PID_A, socket inode $INODE_A)"

"$SOMEWM" >"$LOG_B" 2>&1 &
PID_B=$!
count=0
while ! grep -q 'is held by a running somewm' "$LOG_B" && [ "$count" -lt "$max" ]; do
    sleep 0.1
    count=$(( count + 1 ))
done
grep -q 'is held by a running somewm' "$LOG_B" || fail "B did not refuse A's live socket"
kill -KILL "$PID_B" 2>/dev/null || true
wait "$PID_B" 2>/dev/null || true
PID_B=""

[ -S "$SOCKET" ] || fail "B removed A's socket file"
[ "$(stat -c %i "$SOCKET")" = "$INODE_A" ] || fail "the socket file is not A's"
REPLY="$("$CLIENT" eval 'return 42' 2>&1)" || fail "somewm-client cannot reach A: $REPLY"
case "$REPLY" in
    *42*) ;;
    *) fail "A answered '$REPLY' to 'return 42'" ;;
esac

echo "--- PASS: a running somewm keeps its socket"
exit 0
