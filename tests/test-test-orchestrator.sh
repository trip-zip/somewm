#!/usr/bin/env bash
#
# Test suite for `somewm-client test ...` (issue #158 orchestrator).
#
# Spawns a headless nested somewm under the orchestrator and exercises the
# start / eval / list / stop / --force / already-running paths. Does not
# require a graphical session.
#
# Usage: ./tests/test-test-orchestrator.sh [path-to-somewm] [path-to-somewm-client]

set -e

SOMEWM="${1:-./build-test/somewm}"
SOMEWM_CLIENT="${2:-./build-test/somewm-client}"

if [ ! -x "$SOMEWM" ]; then
    echo "Error: somewm binary not found at $SOMEWM" >&2
    echo "Run 'make build-test' first" >&2
    exit 1
fi
if [ ! -x "$SOMEWM_CLIENT" ]; then
    echo "Error: somewm-client binary not found at $SOMEWM_CLIENT" >&2
    exit 1
fi

# Isolated runtime dir so we don't collide with the user's daily session.
TMP_RUNTIME=$(mktemp -d)
chmod 700 "$TMP_RUNTIME"
export XDG_RUNTIME_DIR="$TMP_RUNTIME"
export SOMEWM_BINARY
SOMEWM_BINARY=$(readlink -f "$SOMEWM")

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_RC="$REPO_ROOT/tests/rc.lua"
if [ ! -f "$TEST_RC" ]; then
    echo "Error: test rc.lua not found at $TEST_RC" >&2
    exit 1
fi

cleanup() {
    "$SOMEWM_CLIENT" test stop --name unit1 >/dev/null 2>&1 || true
    "$SOMEWM_CLIENT" test stop --name unit2 >/dev/null 2>&1 || true
    rm -rf "$TMP_RUNTIME"
}
trap cleanup EXIT INT TERM

pass_count=0
fail_count=0

check() {
    local desc="$1"
    local actual="$2"
    local expected="$3"
    if [ "$actual" = "$expected" ]; then
        echo "  ok: $desc"
        pass_count=$((pass_count + 1))
    else
        echo "  FAIL: $desc"
        echo "    expected: $expected"
        echo "    actual:   $actual"
        fail_count=$((fail_count + 1))
    fi
}

check_match() {
    local desc="$1"
    local actual="$2"
    local pattern="$3"
    if echo "$actual" | grep -qE "$pattern"; then
        echo "  ok: $desc"
        pass_count=$((pass_count + 1))
    else
        echo "  FAIL: $desc"
        echo "    pattern:  $pattern"
        echo "    actual:   $actual"
        fail_count=$((fail_count + 1))
    fi
}

# === Test 1: start, info file present, socket connectable ===
echo "Test 1: start a nested instance"
START_OUT=$("$SOMEWM_CLIENT" test start --name unit1 --host headless --config "$TEST_RC" 2>&1)
check_match "status block names the instance" "$START_OUT" "test 'unit1':"
check_match "status block mentions headless host" "$START_OUT" "host: headless"
check_match "headless status block reports no inhibitor negotiation" "$START_OUT" "no shortcut-inhibitor negotiation"

STATE_DIR="$TMP_RUNTIME/somewm-test/unit1"
[ -f "$STATE_DIR/pid" ] && pid_ok=yes || pid_ok=no
check "pid file written" "$pid_ok" "yes"
[ -S "$STATE_DIR/ipc.sock" ] && sock_ok=yes || sock_ok=no
check "ipc socket exists" "$sock_ok" "yes"
[ -f "$STATE_DIR/info" ] && info_ok=yes || info_ok=no
check "info file written" "$info_ok" "yes"

# === Test 2: eval over the named instance ===
echo "Test 2: eval against the nested instance"
EVAL_OUT=$("$SOMEWM_CLIENT" test eval --name unit1 'return 1+1' 2>&1)
check_match "eval returns 2" "$EVAL_OUT" "(^|[^0-9])2($|[^0-9])"

# === Test 3: list shows the instance ===
echo "Test 3: list"
LIST_OUT=$("$SOMEWM_CLIENT" test list 2>&1)
check_match "list shows unit1" "$LIST_OUT" "unit1"

# === Test 4: already-running rejection (no --force) ===
echo "Test 4: re-start without --force is rejected"
set +e
DUP_OUT=$("$SOMEWM_CLIENT" test start --name unit1 --host headless --config "$TEST_RC" 2>&1)
DUP_RC=$?
set -e
check_match "duplicate start prints already-running error" "$DUP_OUT" "already running"
[ "$DUP_RC" -ne 0 ] && dup_failed=yes || dup_failed=no
check "duplicate start exits non-zero" "$dup_failed" "yes"

# === Test 5: --force replaces ===
echo "Test 5: --force replaces existing instance"
OLD_PID=$(cat "$STATE_DIR/pid")
FORCE_OUT=$("$SOMEWM_CLIENT" test start --name unit1 --host headless --config "$TEST_RC" --force 2>&1)
NEW_PID=$(cat "$STATE_DIR/pid")
check_match "--force prints status block" "$FORCE_OUT" "test 'unit1':"
if [ "$OLD_PID" != "$NEW_PID" ]; then
    pid_changed=yes
else
    pid_changed=no
fi
check "pid changed after --force" "$pid_changed" "yes"

# === Test 6: stop removes the state dir ===
echo "Test 6: stop cleans up"
"$SOMEWM_CLIENT" test stop --name unit1 >/dev/null
[ -e "$STATE_DIR" ] && remains=yes || remains=no
check "state dir is gone after stop" "$remains" "no"

# === Test 7: stop on non-existent instance ===
echo "Test 7: stop on missing instance fails gracefully"
set +e
MISS_OUT=$("$SOMEWM_CLIENT" test stop --name does-not-exist 2>&1)
MISS_RC=$?
set -e
check_match "missing-instance stop prints helpful error" "$MISS_OUT" "No test instance"
[ "$MISS_RC" -ne 0 ] && miss_failed=yes || miss_failed=no
check "missing-instance stop exits non-zero" "$miss_failed" "yes"

# === Summary ===
echo
echo "Passed: $pass_count"
echo "Failed: $fail_count"
[ "$fail_count" -eq 0 ]
