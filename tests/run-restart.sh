#!/usr/bin/env bash
#
# Restart / hot-reload test suite.
#
# Runs tests/restart/*.sh, each against its own sandboxed somewm instance driven
# through `somewm-client test`, so assertions can run on both sides of a real
# awesome.restart(). The in-compositor runner cannot do this: the reload
# destroys the Lua state the test is running in.
#
# Usage:
#   ./tests/run-restart.sh                        # all tests
#   ./tests/run-restart.sh tests/restart/foo.sh   # named tests
#
# Environment:
#   SOMEWM, SOMEWM_CLIENT   binaries (default ./build-test/...)
#   KEEP_LOGS=1             keep instance logs for passing tests too
#   REQUIRE_ALL=1           treat SKIP as a suite failure (CI)
#   SOMEWM_EVAL_PACE        seconds between evals (default 0.5)
#   RESTART_TEST_TIMEOUT    per-test timeout in seconds (default 180)

set -u

# Keep bc and printf on a decimal dot regardless of locale.
export LC_NUMERIC=C

cd "$(dirname "$0")/.."
ROOT_DIR=$PWD
export ROOT_DIR

SOMEWM=${SOMEWM:-./build-test/somewm}
SOMEWM_CLIENT=${SOMEWM_CLIENT:-./build-test/somewm-client}
case $SOMEWM in /*) ;; *) SOMEWM="$ROOT_DIR/${SOMEWM#./}" ;; esac
case $SOMEWM_CLIENT in /*) ;; *) SOMEWM_CLIENT="$ROOT_DIR/${SOMEWM_CLIENT#./}" ;; esac
export SOMEWM SOMEWM_CLIENT

RESTART_TEST_TIMEOUT=${RESTART_TEST_TIMEOUT:-180}
REQUIRE_ALL=${REQUIRE_ALL:-0}
KEEP_LOGS=${KEEP_LOGS:-0}
export KEEP_LOGS

if [ ! -x "$SOMEWM" ]; then
    echo "Error: somewm binary not found at $SOMEWM" >&2
    echo "Run 'make build-test' first" >&2
    exit 1
fi
if [ ! -x "$SOMEWM_CLIENT" ]; then
    echo "Error: somewm-client binary not found at $SOMEWM_CLIENT" >&2
    exit 1
fi

ARTIFACT_DIR=${SOMEWM_RESTART_ARTIFACTS:-$(dirname "$SOMEWM")/restart-artifacts}
export SOMEWM_RESTART_ARTIFACTS="$ARTIFACT_DIR"
rm -rf "$ARTIFACT_DIR"
mkdir -p "$ARTIFACT_DIR"

# One private runtime dir for the whole suite; instances live under
# $XDG_RUNTIME_DIR/somewm-test/<name>/ and are torn down per test.
SUITE_RUNTIME=$(mktemp -d)
chmod 700 "$SUITE_RUNTIME"
export SOMEWM_RESTART_RUNTIME="$SUITE_RUNTIME"

cleanup() {
    rm -rf "$SUITE_RUNTIME"
}
trap cleanup EXIT INT TERM

# dbus-run-session per test, not per suite: an instance still holding
# org.awesomewm.awful must not be able to poison the next test.
DBUS_RUN_SESSION=$(command -v dbus-run-session || true)
if [ -z "$DBUS_RUN_SESSION" ]; then
    if [ "$REQUIRE_ALL" = 1 ]; then
        echo "Error: dbus-run-session not found and REQUIRE_ALL=1" >&2
        exit 1
    fi
    echo "Warning: dbus-run-session not found, D-Bus tests will skip" >&2
    export SOMEWM_NO_DBUS=1
fi

if [ $# -eq 0 ]; then
    tests=$(find tests/restart -maxdepth 1 -name '*.sh' -type f ! -name 'lib.sh' | sort)
else
    tests="$*"
fi

pass_n=0; fail_n=0; xfail_n=0; xpass_n=0; skip_n=0; error_n=0
failed_tests=""
suite_start=$(date +%s.%N)

for t in $tests; do
    name=$(basename "$t" .sh)
    if [ ! -f "$t" ]; then
        echo "Error: no such test: $t" >&2
        error_n=$((error_n + 1))
        failed_tests="$failed_tests $name"
        continue
    fi

    # Read the xfail declaration statically, so the classification survives a
    # test that dies before it can print anything.
    declared=$(sed -nE 's/^# xfail: (D[0-9]+).*/\1/p' "$t" | head -1)

    status_file="$ARTIFACT_DIR/$name.status"
    rm -f "$status_file"
    err_file="$ARTIFACT_DIR/$name.stderr"

    # stdout carries the test's own report, stderr carries whatever the session
    # bus and its activated services have to say. Keeping them apart means the
    # noise can never reach the verdict.
    start=$(date +%s.%N)
    out=$(
        if [ -n "$DBUS_RUN_SESSION" ]; then
            TEST_NAME="$name" timeout "$RESTART_TEST_TIMEOUT" \
                "$DBUS_RUN_SESSION" -- bash "$t" 2>"$err_file"
        else
            TEST_NAME="$name" timeout "$RESTART_TEST_TIMEOUT" bash "$t" 2>"$err_file"
        fi
    )
    rc=$?
    dur=$(echo "$(date +%s.%N) - $start" | bc)

    # finish() writes the tally; no file means the test never reached it.
    asserted=0; assert_failed=0
    if [ -f "$status_file" ]; then
        pass_c=$(sed -nE 's/.*pass=([0-9]+).*/\1/p' "$status_file")
        fail_c=$(sed -nE 's/.*fail=([0-9]+).*/\1/p' "$status_file")
        [ "${pass_c:-0}" -gt 0 ] && asserted=1
        [ "${fail_c:-0}" -gt 0 ] && assert_failed=1
    fi

    # Classify the raw outcome once, then apply the xfail transform to it.
    #
    # A green exit status is not a pass on its own. A test that returns early,
    # or whose last command happens to succeed, exits 0 having asserted
    # nothing, and scoring that as PASS is how a suite goes quietly hollow.
    verdict=""; detail=""; green=1
    case $rc in
        0)   if [ "$asserted" = 1 ]; then outcome=PASS
             else outcome=ERROR; detail="exited 0 without asserting anything"; fi ;;
        77)  outcome=SKIP ;;
        1)   if [ "$assert_failed" = 1 ]; then outcome=FAIL
             else outcome=ERROR; detail="exited 1 without a failed assertion"; fi ;;
        124) outcome=ERROR; detail="timed out after ${RESTART_TEST_TIMEOUT}s" ;;
        *)   outcome=ERROR; detail="exit $rc" ;;
    esac

    if [ "$outcome" = SKIP ]; then
        verdict=SKIP; skip_n=$((skip_n + 1))
        [ "$REQUIRE_ALL" = 1 ] && { green=0; detail="skipped under REQUIRE_ALL=1"; }
    elif [ -z "$declared" ]; then
        verdict=$outcome
        case $outcome in
            PASS)  pass_n=$((pass_n + 1)) ;;
            FAIL)  fail_n=$((fail_n + 1)); green=0 ;;
            ERROR) error_n=$((error_n + 1)); green=0 ;;
        esac
    else
        case $outcome in
            PASS) verdict=XPASS; detail="$declared appears fixed"
                  xpass_n=$((xpass_n + 1)); green=0 ;;
            # An expected failure has to fail for its own reason: an assertion
            # must be what failed, which FAIL already means. Anything else
            # lands in the ERROR arm below as a broken test, not a pinned
            # defect. A first-assertion failure is a legitimate xfail, so this
            # must not also demand a passing assertion.
            FAIL) verdict=XFAIL; detail="$declared"; xfail_n=$((xfail_n + 1)) ;;
            ERROR) verdict=ERROR; error_n=$((error_n + 1)); green=0
                   detail="xfail $declared: ${detail:-broken}" ;;
        esac
    fi

    printf -- '--- %s: %s (%.2fs)\n' "$verdict" "$name" "$dur"
    [ -n "$detail" ] && echo "    $detail"

    if [ "$green" = 0 ]; then
        failed_tests="$failed_tests $name"
        echo "$out" | sed 's/^/    /'
        if [ -s "$err_file" ]; then
            echo "    --- stderr ---"
            tail -20 "$err_file" | sed 's/^/    /'
        fi
        for log in "$ARTIFACT_DIR/$name-"*.log; do
            [ -f "$log" ] || continue
            echo "    --- $log ---"
            tail -60 "$log" | sed 's/^/    /'
            echo "    --- hot-reload markers ---"
            grep -E 'hot-reload:|lgi_guard:|stale GLib sources|outlived the state|FORCEFULLY ABORTED|FATAL:' \
                "$log" | sed 's/^/    /' || echo "    (none)"
        done
        if [ "$verdict" = XPASS ]; then
            echo "    Delete the '# xfail: $declared' line from $t"
            echo "    and update tests/restart/README.md."
        fi
    else
        echo "$out" | grep -E '^  (ok|FAIL|info):' | sed 's/^/    /' || true
        rm -f "$err_file"
        if [ "$KEEP_LOGS" != 1 ]; then
            rm -f "$ARTIFACT_DIR/$name-"*.log
        fi
    fi
    rm -f "$status_file"
done

suite_dur=$(echo "$(date +%s.%N) - $suite_start" | bc)

echo
echo "Passed: $pass_n  XFail: $xfail_n  Skipped: $skip_n  Failed: $fail_n  XPass: $xpass_n  Errors: $error_n"
if [ -n "$failed_tests" ]; then
    echo "Not green:$failed_tests"
fi
[ "$xfail_n" -gt 0 ] && echo "Expected failures pin known defects, see tests/restart/README.md"
echo "artifacts: $ARTIFACT_DIR"
printf 'restart suite %.2fs\n' "$suite_dur"

[ -z "$failed_tests" ]
