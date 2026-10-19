#!/usr/bin/env bash
#
# A live IPC listener is never taken over. An exiting compositor removes its
# own file and then closes its listener, allowing a newer instance to bind
# the same path. Cleanup unlinks the socket only while its inode still
# belongs to that process.
#
# Two headless compositors share one runtime dir: A comes up, gets SIGTERM,
# and B starts during A's exit. The five-second retry in ipc_init lets B
# wait for A to remove its file. A's exit must leave B's socket intact.
#
# Usage: ./tests/test-ipc-socket-handoff.sh [somewm] [somewm-client]

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
EXIT_TIMEOUT=5

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

# Wait until the socket file exists and its inode differs from $2 ("" for any).
wait_socket() {
    local pid="$1" not_inode="$2" count=0 max=$(( START_TIMEOUT * 10 ))
    while [ "$count" -lt "$max" ]; do
        kill -0 "$pid" 2>/dev/null || fail "somewm (pid $pid) exited during startup"
        local inode
        inode="$(stat -c %i "$SOCKET" 2>/dev/null)" || inode=""
        if [ -n "$inode" ] && [ "$inode" != "$not_inode" ]; then
            return 0
        fi
        sleep 0.1
        count=$(( count + 1 ))
    done
    fail "timed out waiting for a socket (pid $pid)"
}

"$SOMEWM" >"$LOG_A" 2>&1 &
PID_A=$!
wait_socket "$PID_A" ""
INODE_A="$(stat -c %i "$SOCKET")"
echo "--- INFO: A up (pid $PID_A, socket inode $INODE_A)"

# Start B during A's exit, before waiting for A to finish.
kill -TERM "$PID_A"
"$SOMEWM" >"$LOG_B" 2>&1 &
PID_B=$!
wait_socket "$PID_B" "$INODE_A"
INODE_B="$(stat -c %i "$SOCKET")"
echo "--- INFO: B up (pid $PID_B, socket inode $INODE_B)"

# Wait for A's exit; its cleanup must leave B's socket alone.
( sleep "$EXIT_TIMEOUT"; kill -KILL "$PID_A" 2>/dev/null ) &
WATCHDOG=$!
wait "$PID_A" 2>/dev/null
kill "$WATCHDOG" 2>/dev/null || true
wait "$WATCHDOG" 2>/dev/null || true
PID_A=""

[ -S "$SOCKET" ] || fail "A's exit removed B's socket file"
[ "$(stat -c %i "$SOCKET")" = "$INODE_B" ] || fail "the socket file is not B's"
REPLY="$("$CLIENT" eval 'return 42' 2>&1)" || fail "somewm-client cannot reach B: $REPLY"
case "$REPLY" in
    *42*) ;;
    *) fail "B answered '$REPLY' to 'return 42'" ;;
esac

echo "--- PASS: the socket path still leads to the newer instance"
echo "PASS"
exit 0
