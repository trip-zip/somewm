#!/usr/bin/env bash
#
# Integration test runner for somewm
#
# Runs somewm and executes Lua test files via IPC

# Force C locale for numeric formatting (bc/printf use dot, not comma)
export LC_NUMERIC=C
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
JOBS=${JOBS:-4}
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
export SOMEWM_SKIP_INSTALLED_LUA=1
export FONTCONFIG_FILE="$ROOT_DIR/tests/fonts.conf"
# tests/xdg holds fixture icons that menubar.utils.lookup_icon finds by name
export XDG_DATA_DIRS="$ROOT_DIR/tests/xdg:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"

# Wayland backend setup based on HEADLESS mode
if [ "$HEADLESS" = 1 ]; then
    export WLR_BACKENDS=headless
    # A renderer already in the environment (WLR_RENDERER=gles2) stays
    export WLR_RENDERER=${WLR_RENDERER:-pixman}
else
    export WLR_BACKENDS=wayland
    # Use GPU renderer in visual mode
fi
export WLR_WL_OUTPUTS=${WLR_WL_OUTPUTS:-1}
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
export SOMEWM_TEST_LOG="$LOG"
[ -n "$SOMEWM_TEST_LOG_DIR" ] && mkdir -p "$SOMEWM_TEST_LOG_DIR"

# Each compositor gets a private session bus, so tests that own D-Bus names
# (notifications, the tray watcher) can run side by side.
DBUS_RUN_SESSION=$(command -v dbus-run-session || true)
if [ -z "$DBUS_RUN_SESSION" ]; then
    echo "Warning: dbus-run-session not found, tests share the host session bus" >&2
fi

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
            kill -TERM -- -"$SOMEWM_PID" 2>/dev/null || true
            # Give it a moment to cleanup
            sleep 0.5
            # Force kill if still running
            kill -KILL -- -"$SOMEWM_PID" 2>/dev/null || true
        fi
        wait $SOMEWM_PID 2>/dev/null || true
    fi

    # Clean up socket in visual mode (it's in real XDG_RUNTIME_DIR)
    [ "$HEADLESS" != 1 ] && [ -n "$SOMEWM_PID" ] && rm -f "$SOCKET" 2>/dev/null || true

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
    # Remove stale socket from previous test. If the prior compositor crashed
    # (core dump, SIGKILL), ipc_cleanup() never ran and the socket file
    # persists. Without this, wait_for_socket() finds the stale file
    # immediately and the IPC connection test fails.
    rm -f "$SOCKET"

    # Start compositor (uses XDG_CONFIG_HOME for config) in its own process
    # group led by SOMEWM_PID. timeout comes first: it moves itself into a new
    # group unless it already leads one.
    setsid timeout "$TEST_TIMEOUT" ${DBUS_RUN_SESSION:+"$DBUS_RUN_SESSION" --} "$SOMEWM" >> "$LOG" 2>&1 &
    SOMEWM_PID=$!

    # Wait for socket
    if ! wait_for_socket; then
        kill -KILL -- -"$SOMEWM_PID" 2>/dev/null || true
        wait $SOMEWM_PID 2>/dev/null || true
        return 1
    fi

    # Test IPC connection
    if ! $SOMEWM_CLIENT eval "return 1" > /dev/null 2>&1; then
        echo "Error: IPC connection test failed" >&2
        echo "Last 50 lines of log:" >&2
        tail -50 "$LOG" >&2
        kill -KILL -- -"$SOMEWM_PID" 2>/dev/null || true
        wait $SOMEWM_PID 2>/dev/null || true
        return 1
    fi

    return 0
}

# A test that called runner.skip wrote "Test skipped." and never the success
# line. Returns 0 if the log holds a skip, 1 otherwise.
log_skipped() {
    grep -q "^Test skipped\.$" "$LOG" && ! grep -q "Test finished successfully\." "$LOG"
}

# Reason a skipping test gave, from its "[SKIP] " line
skip_reason() {
    sed -n 's/^\[SKIP\] //p' "$LOG" | head -1
}

# Run a single test file
# Returns: 0 on success, 1 on failure, 2 when the test skipped
# Sets: TEST_DURATION (seconds with decimals)
run_test() {
    local test_file="$1"
    local timeout=$(sed -n '/^-- timeout: [0-9][0-9]*$/{s/^-- timeout: //;p;q;}' "$test_file")
    local TEST_TIMEOUT="${timeout:-$TEST_TIMEOUT}"
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
        kill -KILL -- -"$SOMEWM_PID" 2>/dev/null || true
        wait $SOMEWM_PID 2>/dev/null || true
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
        kill -KILL -- -"$SOMEWM_PID" 2>/dev/null || true
    fi

    wait $SOMEWM_PID 2>/dev/null || true
    kill -KILL -- -"$SOMEWM_PID" 2>/dev/null || true

    # Kill orphaned test client processes (terminals running "sleep infinity")
    # that may outlive the compositor. Without this, they can reconnect to
    # the next test's compositor and inject unexpected clients. Spawned
    # clients may leave the process group, so ours are the ones that
    # inherited this run's SOMEWM_TEST_LOG.
    local retries=0 found pid
    while [ $retries -lt 10 ]; do
        found=0
        for pid in $(pgrep -f "sleep infinity"); do
            if tr '\0' '\n' 2>/dev/null < /proc/$pid/environ | grep -qxF "SOMEWM_TEST_LOG=$LOG"; then
                kill -9 $pid 2>/dev/null || true
                found=1
            fi
        done
        [ $found -eq 0 ] && break
        sleep 0.1
        retries=$((retries + 1))
    done

    # Record end time
    end_time=$(date +%s.%N)
    TEST_DURATION=$(echo "$end_time - $start_time" | bc)

    log_skipped && return 2

    # Check for success
    if grep -q "Test finished successfully\." "$LOG"; then
        return 0
    else
        return 1
    fi
}

# Run a single test in persistent mode (compositor already running)
# Returns: 0 on success, 1 on failure, 2 when the test skipped
# Sets: TEST_DURATION (seconds with decimals)
run_test_persistent() {
    local test_file="$1"
    local timeout=$(sed -n '/^-- timeout: [0-9][0-9]*$/{s/^-- timeout: //;p;q;}' "$test_file")
    local TEST_TIMEOUT="${timeout:-$TEST_TIMEOUT}"
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
        if log_skipped; then
            end_time=$(date +%s.%N)
            TEST_DURATION=$(echo "$end_time - $start_time" | bc)
            return 2
        fi

        # Check for success
        if grep -q "Test finished successfully\." "$LOG"; then
            end_time=$(date +%s.%N)
            TEST_DURATION=$(echo "$end_time - $start_time" | bc)
            return 0
        fi

        # Check for explicit failure (runner.done with a message)
        if grep -q "^Test failed\.$" "$LOG"; then
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

# Tests with a "-- timeout:" header are the longest, so they start first
first="" rest="" n=0
for test in $tests; do
    if grep -qs '^-- timeout: [0-9][0-9]*$' "$test"; then
        first="$first $test"
    else
        rest="$rest $test"
    fi
    n=$((n + 1))
done
tests="$first$rest"

# Track total time
total_start=$(date +%s.%N)

# Count tests
test_count=0
pass_count=0
fail_count=0
skip_count=0
failed_tests=""

# Print and count one result: 0 pass, 1 fail, 2 skip
report_result() {
    case $1 in
    0)
        pass_count=$((pass_count + 1))
        printf -- "--- PASS: %s (%.2fs)\n" "$test_name" "$TEST_DURATION"
        ;;
    2)
        skip_count=$((skip_count + 1))
        printf -- "--- SKIP: %s (%s)\n" "$test_name" "$(skip_reason)"
        ;;
    *)
        fail_count=$((fail_count + 1))
        failed_tests="$failed_tests $test_name"
        printf -- "--- FAIL: %s (%.2fs)\n" "$test_name" "$TEST_DURATION"
        # Show log on failure
        echo "    Log output:"
        tail -30 "$LOG" | sed 's/^/    /'
        ;;
    esac
}

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
        rc=0
        run_test_persistent "$test" || rc=$?
        report_result $rc

        # Keep this test's compositor output before it is emptied
        [ -n "$SOMEWM_TEST_LOG_DIR" ] && cp "$LOG" "$SOMEWM_TEST_LOG_DIR/$test_name.log"

        # Clear the success marker from log for next test
        > "$LOG"
    done

    # Cleanup: stop compositor
    [ $VERBOSE -eq 1 ] && echo "=== Stopping compositor..."
    kill -TERM $SOMEWM_PID 2>/dev/null || true
    wait $SOMEWM_PID 2>/dev/null || true
    SOMEWM_PID=""
elif [ "$JOBS" != 1 ] && [ $n -gt 1 ]; then
    # Parallel mode: each test runs in a child invocation of this script,
    # which prints its result under the lock and appends it to the results
    results="$TMP_DIR/results"
    : > "$results"
    printf '%s\n' $tests | xargs -P "$JOBS" -n 1 env JOBS=1 \
        SOMEWM_PARALLEL_LOCK="$TMP_DIR/lock" SOMEWM_PARALLEL_RESULTS="$results" \
        "$ROOT_DIR/tests/run-integration.sh" || true
    test_count=$n
    pass_count=$(grep -c '^PASS ' "$results" || true)
    skip_count=$(grep -c '^SKIP ' "$results" || true)
    # A child that wrote no line counts as failed
    fail_count=$((test_count - pass_count - skip_count))
    failed_tests=$(awk '$1 == "FAIL" { printf " %s", $2 }' "$results")
else
    # A parallel child prints its result only when it holds the lock
    if [ -n "$SOMEWM_PARALLEL_RESULTS" ]; then
        exec 3>&1 > "$TMP_DIR/out"
    fi

    # Normal mode: fresh compositor per test
    for test in $tests; do
        test_count=$((test_count + 1))
        test_name=$(basename "$test")

        # Clear log for this test
        > "$LOG"

        # Show test name in verbose mode
        [ $VERBOSE -eq 1 ] && echo "=== RUN   $test_name"

        # Run test
        rc=0
        run_test "$test" || rc=$?
        report_result $rc

        # Keep this test's compositor output before the next test empties it
        [ -n "$SOMEWM_TEST_LOG_DIR" ] && cp "$LOG" "$SOMEWM_TEST_LOG_DIR/$test_name.log"
    done

    if [ -n "$SOMEWM_PARALLEL_RESULTS" ]; then
        result=PASS
        [ $skip_count -gt 0 ] && result=SKIP
        [ $fail_count -gt 0 ] && result=FAIL
        {
            flock 9
            cat "$TMP_DIR/out" >&3
            printf "%s %s %.2f\n" "$result" "$test_name" "$TEST_DURATION" >> "$SOMEWM_PARALLEL_RESULTS"
        } 9>> "$SOMEWM_PARALLEL_LOCK"
        exit $((fail_count > 0))
    fi
fi

# Calculate total time
total_end=$(date +%s.%N)
total_time=$(echo "$total_end - $total_start" | bc)

# Print summary
echo ""
if [ $fail_count -eq 0 ]; then
    echo "PASS"
    printf "ok\t%d passed, %d skipped\t%.2fs\n" "$pass_count" "$skip_count" "$total_time"
else
    echo "FAIL"
    echo "Failed tests:$failed_tests"
    printf "FAIL\t%d passed, %d failed, %d skipped\t%.2fs\n" \
        "$pass_count" "$fail_count" "$skip_count" "$total_time"
fi

if [ $fail_count -gt 0 ]; then
    exit 1
fi

exit 0

# vim: filetype=sh:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
