# Shared harness for the restart/hot-reload test suite.
#
# Sourced by every tests/restart/*.sh. Drives a sandboxed somewm instance through
# `somewm-client test` so assertions can run on both sides of a real
# awesome.restart(), which the in-compositor runner cannot do (the reload
# destroys the Lua state the test lives in).
#
# Usage from a test file:
#
#   # xfail: reason                 # optional, see "Expected failures" below
#   . "$(dirname "$0")/lib.sh"
#   sw_start hr01 --config "$ROOT_DIR/tests/rc.lua"
#   check_eval hr01 "desc" 'return 1+1' 2
#   sw_reload hr01 || finish
#   check_eval hr01 "still works after the reload" 'return 1+1' 2
#   finish

set -u

# --- environment ------------------------------------------------------------

ROOT_DIR=${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
RESTART_DIR="$ROOT_DIR/tests/restart"
SOMEWM=${SOMEWM:-$ROOT_DIR/build-test/somewm}
SOMEWM_CLIENT=${SOMEWM_CLIENT:-$ROOT_DIR/build-test/somewm-client}
case $SOMEWM in /*) ;; *) SOMEWM="$ROOT_DIR/${SOMEWM#./}" ;; esac
case $SOMEWM_CLIENT in /*) ;; *) SOMEWM_CLIENT="$ROOT_DIR/${SOMEWM_CLIENT#./}" ;; esac
BUILD_DIR=$(dirname "$SOMEWM")

TEST_NAME=${TEST_NAME:-$(basename "$0" .sh)}
ARTIFACT_DIR=${SOMEWM_RESTART_ARTIFACTS:-$BUILD_DIR/restart-artifacts}
SOMEWM_EVAL_PACE=${SOMEWM_EVAL_PACE:-0.5}

# The orchestrator must find the compositor, and a failed start must leave the
# state dir (including the log) behind for us to copy.
export SOMEWM_BINARY="$SOMEWM"
export SOMEWM_TEST_KEEP_FAILED=1

# Pin the closure guard to the one built beside the binary under test. The
# compositor self-installs it by re-exec and looks in its compiled-in libdir
# first, so on a machine with somewm installed the build tree's binary preloads
# /usr/local/lib's guard instead of its own. Nothing in the log says which one
# won, and the two can differ in both semantics and message format. Setting it
# here also means the compositor finds the guard already loaded and skips the
# re-exec it would otherwise perform, which is one less variable per test.
if [ -f "$BUILD_DIR/liblgi_closure_guard.so" ]; then
    export LD_PRELOAD="$BUILD_DIR/liblgi_closure_guard.so"
fi

# The fixture configs layer on the shared minimal test config rather than
# copying it, so changes to tests/rc.lua reach this suite too. The orchestrator
# never scrubs the environment, so the compositor inherits this.
export SOMEWM_TEST_BASE_RC="$ROOT_DIR/tests/rc.lua"

# Instances live under our own runtime dir so nothing can collide with the
# developer's session. run-restart.sh sets this; a standalone run makes its own.
if [ -z "${SOMEWM_RESTART_RUNTIME:-}" ]; then
    SOMEWM_RESTART_RUNTIME=$(mktemp -d)
    chmod 700 "$SOMEWM_RESTART_RUNTIME"
    _own_runtime=1
fi
export XDG_RUNTIME_DIR="$SOMEWM_RESTART_RUNTIME"

mkdir -p "$ARTIFACT_DIR"

pass_count=0
fail_count=0
_instances=""
_sandboxes=""
_bg_pids=""

# --- paths ------------------------------------------------------------------

sw_state_dir() { echo "$XDG_RUNTIME_DIR/somewm-test/$1"; }
sw_log()       { echo "$(sw_state_dir "$1")/log"; }
sw_sock()      { echo "$(sw_state_dir "$1")/ipc.sock"; }
sw_pid()       { cat "$(sw_state_dir "$1")/pid" 2>/dev/null || echo ""; }

sw_alive() {
    local pid
    pid=$(sw_pid "$1")
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# --- assertions -------------------------------------------------------------

check() {
    local desc="$1" actual="$2" expected="$3"
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
    local desc="$1" actual="$2" pattern="$3"
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

fail() {
    echo "  FAIL: $1"
    [ $# -gt 1 ] && echo "    $2"
    fail_count=$((fail_count + 1))
}

pass() {
    echo "  ok: $1"
    pass_count=$((pass_count + 1))
}

info() { echo "  info: $*"; }

# --- eval -------------------------------------------------------------------
#
# Wire format is `OK\n<value>\n\n` or `ERROR <msg>\n\n` (lua/awful/ipc.lua:321,
# :344). Command substitution eats the trailing blank line. The exit code is
# authoritative for ERROR (somewm-client.c returns 1 iff the reply starts with
# ERROR); 3 and 4 mean the instance is unreachable, which must never be
# mistaken for a Lua error.
#
# Payloads are single-line only: the orchestrator joins argv with single spaces,
# so use `;` between statements and never a `--` comment.

EVAL_VALUE=""
EVAL_ERROR=""

# Rate-limit before the call rather than sleeping after it, so time already
# spent on other work (a gdbus round trip, a poll loop) counts towards the gap
# and a test never pays for a delay it cannot use. The spacing the compositor
# sees is unchanged.
_last_eval=0

sw_eval() {
    local name="$1" lua="$2" out rc wait
    wait=$(echo "$_last_eval + $SOMEWM_EVAL_PACE - $EPOCHREALTIME" | bc)
    case $wait in -*|0) ;; *) sleep "$wait" ;; esac

    out=$("$SOMEWM_CLIENT" test eval --name "$name" "$lua" 2>&1)
    rc=$?
    _last_eval=$EPOCHREALTIME
    EVAL_VALUE=""
    EVAL_ERROR=""
    case $rc in
        0)
            case $out in
                OK) return 0 ;;
                OK$'\n'*) EVAL_VALUE=${out#OK$'\n'}; return 0 ;;
                *) EVAL_ERROR="malformed reply: $out"; return 2 ;;
            esac
            ;;
        1) EVAL_ERROR=${out#ERROR }; return 1 ;;
        *) EVAL_ERROR="transport rc=$rc: $out"; return 2 ;;
    esac
}

# Retry until the eval succeeds. The IPC socket is created in C and survives the
# reload, but the Lua handler table is rebuilt, so evals can transiently error.
sw_eval_retry() {
    local name="$1" lua="$2" deadline=$((SECONDS + ${3:-10}))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if sw_eval "$name" "$lua"; then
            return 0
        fi
        sw_alive "$name" || { EVAL_ERROR="instance died: $EVAL_ERROR"; return 2; }
    done
    return 1
}

# Poll an eval that returns the string "true" or "false".
sw_wait_true() {
    local name="$1" lua="$2" deadline=$((SECONDS + ${3:-5}))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if sw_eval "$name" "$lua" && [ "$EVAL_VALUE" = "true" ]; then
            return 0
        fi
    done
    return 1
}

check_eval() {
    local name="$1" desc="$2" lua="$3" expected="$4"
    if sw_eval "$name" "$lua"; then
        check "$desc" "$EVAL_VALUE" "$expected"
    else
        fail "$desc" "eval failed: $EVAL_ERROR"
    fi
}

# Arm a gears.timer and wait for it to tick. Timers run on lgi ffi closures, so
# this is the probe for whether the closure guard let the new generation
# through. Shared so that the reload and config-timeout tests, which are a
# control pair, cannot drift apart.
TIMER_ARM='TICKS = 0; require("gears.timer").start_new(0.1, function() TICKS = TICKS + 1; return TICKS < 3 end); return "armed"'
TIMER_FIRED='return tostring(TICKS ~= nil and TICKS >= 3)'

check_timer_fires() {
    local name="$1" desc="$2"
    if ! sw_eval "$name" "$TIMER_ARM" || [ "$EVAL_VALUE" != armed ]; then
        fail "$desc" "could not arm the timer: ${EVAL_ERROR:-$EVAL_VALUE}"
        return 1
    fi
    if sw_wait_true "$name" "$TIMER_FIRED" 5; then
        pass "$desc"
    else
        fail "$desc" "no tick within 5s"
        return 1
    fi
}

# --- clients ----------------------------------------------------------------
#
# Test clients are the C helpers in the build dir, not a terminal: they have
# stable app_ids, do nothing until signalled, and exist on any machine that can
# build somewm. `test run` gives us no pid back, so spawn through awful.spawn
# and keep the pid on the shell side, where it survives the reload.

SPAWN_PID=""
SW_HELPER=""

# Sets SW_HELPER rather than echoing it: skip's `exit 77` would only kill a
# command substitution's subshell, leaving the caller to run the skip message as
# a command.
sw_require_helper() {
    SW_HELPER="$BUILD_DIR/$1"
    [ -x "$SW_HELPER" ] || skip "$1 not built (run 'make build-test')"
}

sw_spawn() {
    local name="$1" cmd="$2"
    SPAWN_PID=""
    if ! sw_eval "$name" "return tostring(require('awful').spawn('$cmd'))"; then
        fail "spawned $cmd" "$EVAL_ERROR"
        return 1
    fi
    case $EVAL_VALUE in
        ''|*[!0-9]*) fail "spawned $cmd" "awful.spawn returned '$EVAL_VALUE'"; return 1 ;;
    esac
    SPAWN_PID=$EVAL_VALUE
    return 0
}

sw_wait_client() {
    local name="$1" class="$2" secs="${3:-10}"
    sw_wait_true "$name" \
        "for _,c in ipairs(client.get()) do if c.class == '$class' then return 'true' end end; return 'false'" \
        "$secs"
}

check_client_appeared() {
    local name="$1" class="$2"
    if sw_wait_client "$name" "$class"; then
        pass "client '$class' appeared"
    else
        fail "client '$class' appeared" "not in client.get() after 10s"
        return 1
    fi
}

# --- log --------------------------------------------------------------------

log_has() { grep -qF -- "$2" "$(sw_log "$1")" 2>/dev/null; }

# Always exactly one number. grep -c prints 0 and exits 1 when it matches
# nothing, and prints nothing at all when the file is missing, so neither the
# status nor the output can be used on its own.
log_count() {
    local n
    n=$(grep -cF -- "$2" "$(sw_log "$1")" 2>/dev/null) || true
    echo "${n:-0}"
}

# Report what each stale-source sweep removed. Printed rather than asserted:
# the count falling to zero is how a later stage shows its teardown contract
# holds, so the number is worth having in every run's output.
sw_report_sweep() {
    grep -oE '(config-timeout: )?removed [0-9]+ stale GLib sources \(baseline=[0-9]+, new_baseline=[0-9]+\)' \
        "$(sw_log "$1")" 2>/dev/null | while read -r line; do info "sweep: $line"; done
}

check_log() {
    local name="$1" desc="$2" needle="$3"
    if log_has "$name" "$needle"; then
        pass "$desc"
    else
        fail "$desc" "log has no '$needle'"
    fi
}

check_log_count() {
    local name="$1" desc="$2" needle="$3" expected="$4" n
    n=$(log_count "$name" "$needle")
    check "$desc" "$n" "$expected"
}

# Blanket gate run after every phase. More than one bug here first announced itself in
# the log while the suite stayed green.
sw_check_log_clean() {
    local name="$1" what="${2:-log}" line
    # A missing log means the instance never ran. Passing here would be a false
    # green, and would also let a broken test masquerade as a pinned defect.
    if [ ! -f "$(sw_log "$name")" ]; then
        fail "$what exists" "no log at $(sw_log "$name")"
        return 1
    fi
    for line in "FATAL:" "error in error handling"; do
        if log_has "$name" "$line"; then
            fail "$what has no '$line'" "$(grep -F -- "$line" "$(sw_log "$name")" | head -3)"
            return 1
        fi
    done
    pass "$what is clean (no FATAL, no error-in-error-handling)"
}

# --- lifecycle --------------------------------------------------------------

sw_start() {
    local name="$1"; shift
    _instances="$_instances $name"
    if ! "$SOMEWM_CLIENT" test start --name "$name" --host headless --force "$@" >/dev/null 2>&1; then
        fail "instance '$name' started"
        _dump_log "$name"
        return 1
    fi
    pass "instance '$name' started"
}

# Start with an env/cwd prefix, for the config-timeout tests which must control
# HOME, XDG_CONFIG_HOME and cwd to pin which config wins the fallback race.
sw_start_env() {
    local name="$1" cwd="$2"; shift 2
    _instances="$_instances $name"
    if ! ( cd "$cwd" && env "$@" "$SOMEWM_CLIENT" test start --name "$name" --host headless --force ) >/dev/null 2>&1; then
        fail "instance '$name' started"
        _dump_log "$name"
        return 1
    fi
    pass "instance '$name' started"
}

# Reload and wait for it to actually complete.
#
# Two barriers, both required. `test reload` returns as soon as the IPC handler
# queues the GLib idle, so its exit status proves nothing.
#
#  1. The `hot-reload: complete` count must strictly increase. The log is opened
#     O_TRUNC once at start and appended for the instance's life, so counting is
#     valid across repeated reloads.
#  2. awesome._restart must read true through a fresh eval, proving the new
#     state re-ran rc.lua and is serving IPC again. It is set well before
#     `complete` (luaa.c:5386), so it is not sufficient on its own.
#
# `lgi_guard: ... marked ready` is deliberately not a barrier: it is emitted
# only when the LD_PRELOAD guard is installed.
sw_reload() {
    local name="$1" timeout="${2:-25}" log before now deadline
    log=$(sw_log "$name")
    before=$(log_count "$name" "hot-reload: complete")

    if ! "$SOMEWM_CLIENT" test reload --name "$name" >/dev/null 2>&1; then
        fail "reload accepted by '$name'"
        return 1
    fi

    deadline=$((SECONDS + timeout))
    now=$before
    while [ "$SECONDS" -lt "$deadline" ]; do
        if ! sw_alive "$name"; then
            fail "instance '$name' survived the reload" "process died"
            return 1
        fi
        now=$(log_count "$name" "hot-reload: complete")
        [ "$now" -gt "$before" ] && break
        sleep 0.05
    done

    if [ "$now" -le "$before" ]; then
        fail "reload completed within ${timeout}s" "no new 'hot-reload: complete' in $log"
        return 1
    fi

    if ! sw_eval_retry "$name" 'return tostring(awesome._restart)' 10; then
        fail "instance '$name' serves IPC after reload" "$EVAL_ERROR"
        return 1
    fi
    if [ "$EVAL_VALUE" != "true" ]; then
        fail "awesome._restart is true after reload" "got '$EVAL_VALUE'"
        return 1
    fi
    pass "reload completed"
}

sw_stop() {
    local name="$1" log
    log=$(sw_log "$name")
    [ -f "$log" ] && cp "$log" "$ARTIFACT_DIR/$TEST_NAME-$name.log" 2>/dev/null
    "$SOMEWM_CLIENT" test stop --name "$name" >/dev/null 2>&1 || true
    _instances=$(echo "$_instances" | tr ' ' '\n' | grep -vx "$name" | tr '\n' ' ')
}

# --- D-Bus ------------------------------------------------------------------
#
# Every call is wrapped in a timeout: a dead dispatcher's symptom is that
# replies never come, and an unbounded gdbus hangs the suite instead of failing.
#
# BUS_OUT holds stdout. Never assert on the exit status alone: a dead remote-eval endpoint's
# signature is empty output with exit 0.

BUS_OUT=""

sw_bus() {
    BUS_OUT=$(timeout 5 gdbus call --session "$@" 2>&1)
    return $?
}

sw_bus_call() {
    local dest="$1" path="$2" method="$3"; shift 3
    sw_bus --dest "$dest" --object-path "$path" --method "$method" "$@"
}

# Resolve a bus name to the owning process id. dbus-run-session still honours
# /usr/share/dbus-1/services, so a real notification daemon can be activated on
# the "private" bus; without this check the issue-444 regression test would be
# permanently and silently green.
sw_bus_owner_pid() {
    local owner
    sw_bus_call org.freedesktop.DBus /org/freedesktop/DBus \
        org.freedesktop.DBus.GetNameOwner "$1" || return 1
    owner=$(echo "$BUS_OUT" | sed -nE "s/^\('([^']+)',\)$/\1/p")
    [ -n "$owner" ] || return 1
    sw_bus_call org.freedesktop.DBus /org/freedesktop/DBus \
        org.freedesktop.DBus.GetConnectionUnixProcessID "$owner" || return 1
    echo "$BUS_OUT" | sed -nE 's/^\(uint32 ([0-9]+),\)$/\1/p'
}

check_bus_owner() {
    local name="$1" busname="$2" desc="$3"
    check "$desc" "$(sw_bus_owner_pid "$busname" || true)" "$(sw_pid "$name")"
}

# Preflight for the tests that talk to the bus from outside the compositor.
skip_unless_bus() {
    [ -z "${SOMEWM_NO_DBUS:-}" ] || skip "dbus-run-session not available"
    skip_unless_cmd gdbus "gdbus not available"
    [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] || skip "no session bus (run under dbus-run-session)"
}

# --- config-timeout mode ----------------------------------------------------
#
# A config that blocks past the compositor's 10 second alarm is aborted with
# SIGALRM + siglongjmp, and the compositor falls through to the next config in
# its search order. Reaching that path needs no --config, which means the search
# order has to be pinned or the test silently runs somebody else's config:
#
#   $XDG_CONFIG_HOME/somewm/rc.lua   the hanging one
#   $HOME/.config/awesome/rc.lua     must not exist, hence an empty HOME
#   SYSCONFDIR/xdg/somewm/rc.lua     relative to cwd, absent in the sandbox
#   ./somewmrc.lua                   the fallback we control, hence the cwd
#
# The sandbox also carries a ./lua symlink into the repo. package.path puts
# ./lua ahead of DATADIR, so without it a machine with somewm installed would
# load /usr/local/share/somewm/lua instead of the tree under test.

SW_TIMEOUT_CWD=""
SW_TIMEOUT_HOME=""
SW_TIMEOUT_CONFIG=""

sw_timeout_sandbox() {
    local box
    box=$(sw_sandbox)
    mkdir -p "$box/cwd" "$box/home" "$box/config/somewm"
    cp "$RESTART_DIR/configs/hang/somewm/rc.lua" "$box/config/somewm/rc.lua"
    cp "$RESTART_DIR/configs/fallback/somewmrc.lua" "$box/cwd/somewmrc.lua"
    ln -s "$ROOT_DIR/lua" "$box/cwd/lua"
    SW_TIMEOUT_CWD="$box/cwd"
    SW_TIMEOUT_HOME="$box/home"
    SW_TIMEOUT_CONFIG="$box/config"
}

# Start an instance whose config hangs, and wait out the abort. Asserts the
# startup gate: the hang really was aborted, and the fallback we control really
# is what loaded.
sw_start_hung_config() {
    local name="$1"
    sw_timeout_sandbox
    sw_start_env "$name" "$SW_TIMEOUT_CWD" \
        HOME="$SW_TIMEOUT_HOME" \
        XDG_CONFIG_HOME="$SW_TIMEOUT_CONFIG" \
        SOMEWM_TEST_FALLBACK_RC="$ROOT_DIR/tests/rc.lua" \
        || return 1

    if log_has "$name" "FORCEFULLY ABORTED after timeout"; then
        pass "the hanging config was aborted"
    else
        fail "the hanging config was aborted" "no abort line in the log"
        return 1
    fi

    # Ask the compositor which config won, rather than reading the log: the
    # "loaded config from" line goes through wlr_log, whose verbosity is pinned
    # to silent, so it never reaches the log at all. conffile only reports
    # "./somewmrc.lua", so the marker global is what identifies it as ours.
    if ! sw_eval "$name" 'return tostring(awesome.conffile) .. "/" .. tostring(SOMEWM_TEST_FALLBACK)'; then
        fail "the fallback config we control is what loaded" "$EVAL_ERROR"
        return 1
    fi
    check "the fallback config we control is what loaded" \
        "$EVAL_VALUE" "./somewmrc.lua/true"
}

# --- misc -------------------------------------------------------------------

sw_sandbox() {
    local d
    d=$(mktemp -d)
    _sandboxes="$_sandboxes $d"
    echo "$d"
}

sw_bg() { _bg_pids="$_bg_pids $1"; }

skip() {
    echo "SKIP: $TEST_NAME: $*"
    exit 77
}

skip_unless_cmd() {
    command -v "$1" >/dev/null 2>&1 || skip "${2:-$1 not available}"
}

# Expected failures are declared by a comment near the top of a test file:
#
#   # xfail: naughty never re-owns its bus name after a reload
#
# run-restart.sh reads it statically, before running anything, so the
# classification survives a test that dies early. It is a comment rather than a
# call so that it cannot depend on this file having been sourced yet.

_dump_log() {
    local log
    log=$(sw_log "$1")
    if [ -f "$log" ]; then
        cp "$log" "$ARTIFACT_DIR/$TEST_NAME-$1.log" 2>/dev/null
        echo "    --- last 30 lines of $1 log ---"
        tail -30 "$log" | sed 's/^/    /'
    fi
}

_cleanup() {
    local rc=$? name pid d
    for pid in $_bg_pids; do kill "$pid" 2>/dev/null || true; done
    for name in $_instances; do sw_stop "$name"; done
    for d in $_sandboxes; do rm -rf "$d"; done
    [ "${_own_runtime:-0}" = 1 ] && rm -rf "$SOMEWM_RESTART_RUNTIME"
    return $rc
}
trap _cleanup EXIT INT TERM

# Print the tally, hand it to the runner, and exit.
#
# The status file is how run-restart.sh knows whether the test asserted anything
# and whether an assertion failed. Reporting it structurally means a test that
# is killed part-way through simply leaves no status file and is classified as
# an error, rather than being scored on whatever it had printed by then.
#
# This exits rather than returning so that `sw_start ... || finish` genuinely
# stops the test: continuing against an instance that never started produces a
# cascade of meaningless failures and can even manufacture false passes.
finish() {
    echo
    echo "Passed: $pass_count"
    echo "Failed: $fail_count"
    printf 'pass=%d fail=%d\n' "$pass_count" "$fail_count" \
        > "$ARTIFACT_DIR/$TEST_NAME.status"
    [ "$fail_count" -eq 0 ]
    exit $?
}
