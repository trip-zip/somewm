#!/usr/bin/env bash
#
# Integration test runner for somewm
#
# Runs somewm and executes Lua test files via IPC
#
# Modes:
#   HEADLESS=1 (default): Run with headless backend (reliable, for CI)
#   HEADLESS=0: Run with wayland backend (visual, for debugging)
#   PERSISTENT=0 (default): Start fresh compositor per test
#   PERSISTENT=1: Keep compositor running, reset state between tests (10x faster)
#
# Output:
#   VERBOSE=0 (default): Quiet, only show PASS/FAIL with timing
#   VERBOSE=1: Show test names before running

set -e

# Configuration
SOMEWM="${SOMEWM:-./somewm}"
SOMEWM_CLIENT="${SOMEWM_CLIENT:-./somewm-client}"
TEST_TIMEOUT=${TEST_TIMEOUT:-30}
VERBOSE=${VERBOSE:-0}
HEADLESS=${HEADLESS:-0}
PERSISTENT=${PERSISTENT:-0}
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

# Wayland backend setup based on HEADLESS mode
if [ "$HEADLESS" = 1 ]; then
    export WLR_BACKENDS=headless
    export WLR_RENDERER=pixman
else
    export WLR_BACKENDS=wayland
    # Use GPU renderer in visual mode
fi
export WLR_WL_OUTPUTS=1
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
# In visual mode, keep real XDG_RUNTIME_DIR so somewm can find parent compositor
if [ "$HEADLESS" = 1 ]; then
    export XDG_RUNTIME_DIR="$TEST_RUNTIME_DIR"
    SOCKET="$XDG_RUNTIME_DIR/somewm-socket"
else
    # Visual mode: use unique socket to avoid conflict with running somewm
    SOCKET="$XDG_RUNTIME_DIR/somewm-test-$$"
    export SOMEWM_SOCKET="$SOCKET"
fi
export XDG_CONFIG_HOME="$TMP_DIR/config"

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

    # Clean up socket in visual mode (it's in real XDG_RUNTIME_DIR)
    [ "$HEADLESS" != 1 ] && rm -f "$SOCKET" 2>/dev/null || true

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

# Start somewm
start_somewm() {
    # Start compositor (uses XDG_CONFIG_HOME for config)
    timeout $TEST_TIMEOUT "$SOMEWM" > "$LOG" 2>&1 &
    SOMEWM_PID=$!

    # Wait for socket
    if ! wait_for_socket; then
        return 1
    fi

    # Test IPC connection
    if ! $SOMEWM_CLIENT eval "return 1" > /dev/null 2>&1; then
        echo "Error: IPC connection test failed" >&2
        echo "Last 50 lines of log:" >&2
        tail -50 "$LOG" >&2
        return 1
    fi

    return 0
}

# Run a single test file
# Returns: 0 on success, 1 on failure
# Sets: TEST_DURATION (seconds with decimals)
run_test() {
    local test_file="$1"
    local test_name=$(basename "$test_file")
    local start_time end_time

    # Record start time
    start_time=$(date +%s.%N)

    # Start compositor
    if ! start_somewm; then
        end_time=$(date +%s.%N)
        TEST_DURATION=$(echo "$end_time - $start_time" | bc)
        return 1
    fi

    # Execute test via IPC
    local test_path="$ROOT_DIR/$test_file"
    if [ ! -f "$test_path" ]; then
        echo "Error: Test file not found: $test_path" >&2
        end_time=$(date +%s.%N)
        TEST_DURATION=$(echo "$end_time - $start_time" | bc)
        return 1
    fi

    # Run the test with timeout on IPC call (capture output to log only)
    echo "=== Test starting at $(date) ===" >> "$LOG"
    timeout $TEST_TIMEOUT $SOMEWM_CLIENT eval "dofile('$test_path')" >> "$LOG" 2>&1
    local ipc_exit=$?

    # If IPC timed out, kill compositor and fail
    if [ $ipc_exit -eq 124 ]; then
        kill -KILL $SOMEWM_PID 2>/dev/null || true
        end_time=$(date +%s.%N)
        TEST_DURATION=$(echo "$end_time - $start_time" | bc)
        return 1
    fi

    # Wait for compositor to exit with timeout
    # (wait_count increments every 0.1s, so multiply timeout by 10)
    local wait_count=0
    local max_wait=$((TEST_TIMEOUT * 10))
    while kill -0 $SOMEWM_PID 2>/dev/null && [ $wait_count -lt $max_wait ]; do
        sleep 0.1
        wait_count=$((wait_count + 1))
    done

    # Force kill if still running
    if kill -0 $SOMEWM_PID 2>/dev/null; then
        kill -KILL $SOMEWM_PID 2>/dev/null || true
    fi

    wait $SOMEWM_PID 2>/dev/null || true

    # Record end time
    end_time=$(date +%s.%N)
    TEST_DURATION=$(echo "$end_time - $start_time" | bc)

    # Check for success
    if grep -q "Test finished successfully\." "$LOG"; then
        return 0
    else
        return 1
    fi
}

# Run a single test in persistent mode (compositor already running)
# Returns: 0 on success, 1 on failure
# Sets: TEST_DURATION (seconds with decimals)
run_test_persistent() {
    local test_file="$1"
    local test_name=$(basename "$test_file")
    local start_time end_time

    # Record start time
    start_time=$(date +%s.%N)

    # Reset state before test and enable persistent mode
    if ! $SOMEWM_CLIENT eval "local runner = require('_runner'); runner.set_persistent(true); runner.reset_state(); require('_state').reset()" >> "$LOG" 2>&1; then
        echo "Error: Failed to reset state before test" >&2
        end_time=$(date +%s.%N)
        TEST_DURATION=$(echo "$end_time - $start_time" | bc)
        return 1
    fi

    # Wait briefly for state reset to complete
    sleep 0.1

    # Execute test via IPC
    local test_path="$ROOT_DIR/$test_file"
    if [ ! -f "$test_path" ]; then
        echo "Error: Test file not found: $test_path" >&2
        end_time=$(date +%s.%N)
        TEST_DURATION=$(echo "$end_time - $start_time" | bc)
        return 1
    fi

    # Clear log marker for this test
    echo "=== Test $test_name starting at $(date) ===" >> "$LOG"

    # Run the test (dofile returns immediately for async tests)
    $SOMEWM_CLIENT eval "dofile('$test_path')" >> "$LOG" 2>&1

    # Poll for test completion (check log for success/error message)
    local wait_count=0
    local max_wait=$((TEST_TIMEOUT * 10))  # 10 checks per second
    while [ $wait_count -lt $max_wait ]; do
        # Check for success
        if grep -q "Test finished successfully\." "$LOG"; then
            end_time=$(date +%s.%N)
            TEST_DURATION=$(echo "$end_time - $start_time" | bc)
            return 0
        fi

        # Check for explicit failure
        if grep -q "^Error: " "$LOG"; then
            end_time=$(date +%s.%N)
            TEST_DURATION=$(echo "$end_time - $start_time" | bc)
            return 1
        fi

        sleep 0.1
        wait_count=$((wait_count + 1))
    done

    # Timeout
    echo "=== Test timed out ===" >> "$LOG"
    end_time=$(date +%s.%N)
    TEST_DURATION=$(echo "$end_time - $start_time" | bc)
    return 1
}

# Get test files
if [ $# -eq 0 ]; then
    # Default to all test-*.lua files
    tests=$(find tests -name "test-*.lua" -type f 2>/dev/null | sort || echo "")
    if [ -z "$tests" ]; then
        echo "Error: No test files found in tests/" >&2
        exit 1
    fi
else
    tests="$@"
fi

# Track total time
total_start=$(date +%s.%N)

# Count tests
test_count=0
pass_count=0
fail_count=0
failed_tests=""

# Run tests based on mode
if [ "$PERSISTENT" = 1 ]; then
    # Persistent mode: start compositor once, reset state between tests
    [ $VERBOSE -eq 1 ] && echo "=== Starting compositor in persistent mode..."

    if ! start_somewm; then
        echo "Error: Failed to start compositor for persistent mode" >&2
        exit 1
    fi

    [ $VERBOSE -eq 1 ] && echo "=== Compositor started, running tests..."

    for test in $tests; do
        test_count=$((test_count + 1))
        test_name=$(basename "$test")

        # Show test name in verbose mode
        [ $VERBOSE -eq 1 ] && echo "=== RUN   $test_name"

        # Run test in persistent mode
        if run_test_persistent "$test"; then
            pass_count=$((pass_count + 1))
            printf -- "--- PASS: %s (%.2fs)\n" "$test_name" "$TEST_DURATION"
        else
            fail_count=$((fail_count + 1))
            failed_tests="$failed_tests $test_name"
            printf -- "--- FAIL: %s (%.2fs)\n" "$test_name" "$TEST_DURATION"
            # Show log on failure
            echo "    Log output:"
            tail -30 "$LOG" | sed 's/^/    /'
        fi

        # Clear the success marker from log for next test
        > "$LOG"
    done

    # Cleanup: stop compositor
    [ $VERBOSE -eq 1 ] && echo "=== Stopping compositor..."
    kill -TERM $SOMEWM_PID 2>/dev/null || true
    wait $SOMEWM_PID 2>/dev/null || true
    SOMEWM_PID=""
else
    # Normal mode: fresh compositor per test
    for test in $tests; do
        test_count=$((test_count + 1))
        test_name=$(basename "$test")

        # Clear log for this test
        > "$LOG"

        # Show test name in verbose mode
        [ $VERBOSE -eq 1 ] && echo "=== RUN   $test_name"

        # Run test
        if run_test "$test"; then
            pass_count=$((pass_count + 1))
            printf -- "--- PASS: %s (%.2fs)\n" "$test_name" "$TEST_DURATION"
        else
            fail_count=$((fail_count + 1))
            failed_tests="$failed_tests $test_name"
            printf -- "--- FAIL: %s (%.2fs)\n" "$test_name" "$TEST_DURATION"
            # Show log on failure
            echo "    Log output:"
            tail -30 "$LOG" | sed 's/^/    /'
        fi
    done
fi

# Calculate total time
total_end=$(date +%s.%N)
total_time=$(echo "$total_end - $total_start" | bc)

# Print summary
echo ""
if [ $fail_count -eq 0 ]; then
    echo "PASS"
else
    echo "FAIL"
    echo "Failed tests:$failed_tests"
fi
printf "ok\t%d tests\t%.2fs\n" "$test_count" "$total_time"

if [ $fail_count -gt 0 ]; then
    exit 1
fi

exit 0

# vim: filetype=sh:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
