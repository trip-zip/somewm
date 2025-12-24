#!/usr/bin/env bash
#
# Integration test runner for somewm
#
# Runs somewm in headless mode and executes Lua test files via IPC

set -e

# Configuration
SOMEWM="${SOMEWM:-./somewm}"
SOMEWM_CLIENT="${SOMEWM_CLIENT:-./somewm-client}"
TEST_TIMEOUT=${TEST_TIMEOUT:-30}
VERBOSE=${VERBOSE:-0}
TEST_RC_LUA="${TEST_RC_LUA:-}"

# Change to script's directory
cd "$(dirname "$0")/.."
ROOT_DIR="$PWD"

# Use minimal test config by default
if [ -z "$TEST_RC_LUA" ]; then
    TEST_RC_LUA="$ROOT_DIR/tests/rc.lua"
fi

# Setup Lua path to include tests directory
export LUA_PATH="$ROOT_DIR/lua/?.lua;$ROOT_DIR/lua/?/init.lua;$ROOT_DIR/tests/?.lua;;"

# Wayland backend setup for headless mode
export WLR_BACKENDS=headless
export WLR_WL_OUTPUTS=1
export WLR_RENDERER=pixman
export NO_AT_BRIDGE=1
export GDK_SCALE=1

# Check binaries exist
if [ ! -x "$SOMEWM" ]; then
    echo "Error: somewm binary not found at $SOMEWM" >&2
    echo "Run 'make' first" >&2
    exit 1
fi

if [ ! -x "$SOMEWM_CLIENT" ]; then
    echo "Error: somewm-client binary not found at $SOMEWM_CLIENT" >&2
    echo "Run 'make' first" >&2
    exit 1
fi

# Setup temp directory and log file
TMP_DIR=$(mktemp -d)
LOG="$TMP_DIR/somewm.log"

# Create isolated runtime directory for test compositor
TEST_RUNTIME_DIR="$TMP_DIR/runtime"
mkdir -p "$TEST_RUNTIME_DIR"
chmod 700 "$TEST_RUNTIME_DIR"

# Create test config directory
TEST_CONFIG_DIR="$TMP_DIR/config/somewm"
mkdir -p "$TEST_CONFIG_DIR"
cp "$TEST_RC_LUA" "$TEST_CONFIG_DIR/rc.lua"

# Override XDG directories for test compositor to avoid conflicts
export XDG_RUNTIME_DIR="$TEST_RUNTIME_DIR"
export XDG_CONFIG_HOME="$TMP_DIR/config"
SOCKET="$XDG_RUNTIME_DIR/somewm-socket"

# Cleanup function
cleanup() {
    local exit_code=$?

    if [ -n "$SOMEWM_PID" ]; then
        if kill -0 $SOMEWM_PID 2>/dev/null; then
            kill -TERM $SOMEWM_PID 2>/dev/null || true
            # Give it a moment to cleanup
            sleep 0.5
            # Force kill if still running
            kill -KILL $SOMEWM_PID 2>/dev/null || true
        fi
        wait $SOMEWM_PID 2>/dev/null || true
    fi

    rm -rf "$TMP_DIR" || true

    return $exit_code
}
trap cleanup EXIT INT TERM

# Wait for socket to appear
wait_for_socket() {
    local count=0
    local max_wait=300  # 30 seconds (300 * 0.1s)

    while [ ! -S "$SOCKET" ] && [ $count -lt $max_wait ]; do
        sleep 0.1
        count=$((count + 1))
    done

    if [ ! -S "$SOCKET" ]; then
        echo "Error: Timeout waiting for somewm socket" >&2
        echo "Last 50 lines of log:" >&2
        tail -50 "$LOG" >&2
        return 1
    fi

    return 0
}

# Start somewm in headless mode
start_somewm() {
    [ $VERBOSE -eq 1 ] && echo "Starting somewm in headless mode..."
    [ $VERBOSE -eq 1 ] && echo "Using config: $TEST_CONFIG_DIR/rc.lua"

    # Start compositor (uses XDG_CONFIG_HOME for config)
    timeout $TEST_TIMEOUT "$SOMEWM" > "$LOG" 2>&1 &
    SOMEWM_PID=$!

    [ $VERBOSE -eq 1 ] && echo "somewm started with PID $SOMEWM_PID"

    # Wait for socket
    if ! wait_for_socket; then
        return 1
    fi

    [ $VERBOSE -eq 1 ] && echo "Socket ready at $SOCKET"

    # Test IPC connection
    if ! $SOMEWM_CLIENT eval "return 1" > /dev/null 2>&1; then
        echo "Error: IPC connection test failed" >&2
        echo "Last 50 lines of log:" >&2
        tail -50 "$LOG" >&2
        return 1
    fi

    [ $VERBOSE -eq 1 ] && echo "IPC connection verified"

    return 0
}

# Run a single test file
run_test() {
    local test_file="$1"
    local test_name=$(basename "$test_file")

    echo "=== Running $test_name ==="

    # Start compositor
    if ! start_somewm; then
        echo "FAIL: $test_name (compositor failed to start)"
        return 1
    fi

    # Execute test via IPC
    local test_path="$ROOT_DIR/$test_file"
    if [ ! -f "$test_path" ]; then
        echo "Error: Test file not found: $test_path" >&2
        return 1
    fi

    # Run the test with timeout on IPC call
    echo "=== Test starting at $(date) ===" >> "$LOG"
    timeout $TEST_TIMEOUT $SOMEWM_CLIENT eval "dofile('$test_path')" 2>&1 | tee -a "$LOG"
    local ipc_exit=$?

    # If IPC timed out, kill compositor and fail
    if [ $ipc_exit -eq 124 ]; then
        echo "Error: IPC call timed out after $TEST_TIMEOUT seconds" >&2
        kill -KILL $SOMEWM_PID 2>/dev/null || true
        echo "FAIL: $test_name (IPC timeout)"
        return 1
    fi

    # Tail log in background while waiting for compositor to exit
    tail -f "$LOG" --pid=$SOMEWM_PID 2>/dev/null &
    local tail_pid=$!

    # Wait for compositor to exit with timeout
    local wait_count=0
    while kill -0 $SOMEWM_PID 2>/dev/null && [ $wait_count -lt $TEST_TIMEOUT ]; do
        sleep 1
        wait_count=$((wait_count + 1))
    done

    # Force kill if still running
    if kill -0 $SOMEWM_PID 2>/dev/null; then
        echo "Warning: Compositor did not exit, force killing" >&2
        kill -KILL $SOMEWM_PID 2>/dev/null || true
    fi

    wait $SOMEWM_PID 2>/dev/null || true
    local compositor_exit=$?

    # Stop tail
    kill $tail_pid 2>/dev/null || true
    wait $tail_pid 2>/dev/null || true

    # Check for success
    if grep -q "Test finished successfully\." "$LOG"; then
        echo "PASS: $test_name"
        return 0
    else
        echo "FAIL: $test_name"
        echo "Last 50 lines of log:"
        tail -50 "$LOG"
        return 1
    fi
}

# Get test files
if [ $# -eq 0 ]; then
    # Default to all test-*.lua files
    tests=$(find tests -name "test-*.lua" -type f 2>/dev/null || echo "")
    if [ -z "$tests" ]; then
        echo "Error: No test files found in tests/" >&2
        exit 1
    fi
else
    tests="$@"
fi

# Count tests
test_count=0
pass_count=0
fail_count=0

# Run each test
for test in $tests; do
    test_count=$((test_count + 1))

    # Clear log for this test
    > "$LOG"

    # Run test
    if run_test "$test"; then
        pass_count=$((pass_count + 1))
    else
        fail_count=$((fail_count + 1))
    fi

    echo ""
done

# Print summary
echo "================================"
echo "Test Summary:"
echo "  Total:  $test_count"
echo "  Passed: $pass_count"
echo "  Failed: $fail_count"
echo "================================"

if [ $fail_count -gt 0 ]; then
    exit 1
fi

exit 0

# vim: filetype=sh:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
