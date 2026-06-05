#!/usr/bin/env bash
#
# Reproducer for the wl_display_flush_clients re-entrance crash inside
# mapnotify (somewm.c). See trip-zip/somewm#530.
#
# Spawns a nested somewm and repeatedly launches a tiny xdg-shell client that
# disconnects right after its mapping commit. Without the fix, one of the
# iterations triggers
#
#   somewm: types/wlr_compositor.c:735: surface_handle_resource_destroy:
#     Assertion `wl_list_empty(&surface->events.map.listener_list)' failed.
#
# and the compositor dies with SIGABRT. With the fix, the compositor survives
# all iterations.
#
# Exit codes:
#   0  compositor survived all iterations (PASS)
#   1  compositor died (REPRO confirmed; either a missing fix or a regression)
#   2  test infrastructure problem (binary missing, sandbox setup failed, ...)
#
# Env knobs:
#   ITERATIONS=200   how many disconnect-mid-map clients to spawn (default 200)
#   ROUND_DELAY=0    seconds to sleep between iterations (default 0, fastest)
#   SOMEWM_BINARY    explicit somewm binary (otherwise auto-pick build-test/build/...)
#   SOMEWM_CLIENT    explicit somewm-client binary
#   TEST_CLIENT      explicit test-disconnect-mid-map-client binary
#   KEEP_LOGS=1      do not delete the compositor/client logs on success

set -u

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ITERATIONS=${ITERATIONS:-200}
ROUND_DELAY=${ROUND_DELAY:-0}
KEEP_LOGS=${KEEP_LOGS:-0}

# A bad ITERATIONS must not silently run zero iterations and report a
# meaningless PASS.
case $ITERATIONS in
	'' | *[!0-9]*)
		echo "ERROR: ITERATIONS must be a positive integer, got '$ITERATIONS'" >&2
		exit 2
		;;
esac
if [ "$ITERATIONS" -lt 1 ]; then
	echo "ERROR: ITERATIONS must be >= 1, got '$ITERATIONS'" >&2
	exit 2
fi

# The nested somewm loads the in-tree lua/ tree; make require() resolve
# regardless of the caller's CWD (matches tests/run-integration.sh).
export LUA_PATH="$ROOT_DIR/lua/?.lua;$ROOT_DIR/lua/?/init.lua;$ROOT_DIR/tests/?.lua;;"

pick() {
	local var=$1; shift
	local current=${!var:-}
	if [ -n "$current" ] && [ -x "$current" ]; then
		printf '%s\n' "$current"
		return 0
	fi
	for c in "$@"; do
		[ -x "$c" ] && { printf '%s\n' "$c"; return 0; }
	done
	return 1
}

SOMEWM=$(pick SOMEWM_BINARY \
	"$ROOT_DIR/build-test/somewm" \
	"$ROOT_DIR/build/somewm" \
	"$ROOT_DIR/build-fx/somewm") || {
	echo "ERROR: no somewm binary; build with 'make build-test' or set SOMEWM_BINARY" >&2
	exit 2
}

CLIENT=$(pick SOMEWM_CLIENT \
	"$ROOT_DIR/build-test/somewm-client" \
	"$ROOT_DIR/build/somewm-client" \
	"$ROOT_DIR/build-fx/somewm-client") || {
	echo "ERROR: no somewm-client binary" >&2
	exit 2
}

TESTC=$(pick TEST_CLIENT \
	"$ROOT_DIR/build-test/test-disconnect-mid-map-client" \
	"$ROOT_DIR/build/test-disconnect-mid-map-client" \
	"$ROOT_DIR/build-fx/test-disconnect-mid-map-client") || {
	echo "ERROR: test-disconnect-mid-map-client not built; run meson + ninja" >&2
	exit 2
}

if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
	echo "ERROR: XDG_RUNTIME_DIR is not set" >&2
	exit 2
fi
if [ -z "${WAYLAND_DISPLAY:-}" ]; then
	echo "ERROR: WAYLAND_DISPLAY is not set; this test needs a parent Wayland session" >&2
	exit 2
fi

LOGDIR=$(mktemp -d)
COMP_LOG="$LOGDIR/compositor.log"
SOCKET="$XDG_RUNTIME_DIR/somewm-disconnect-test-$$.sock"
PARENT_DISPLAY=$WAYLAND_DISPLAY

cleanup() {
	local code=$?
	if [ -n "${COMP_PID:-}" ] && kill -0 "$COMP_PID" 2>/dev/null; then
		# The nested somewm under WLR_BACKENDS=wayland does not always
		# react to SIGTERM (it stays inside its event loop). Give it a
		# short grace period and then SIGKILL so cleanup never wedges.
		kill -TERM "$COMP_PID" 2>/dev/null || true
		for _ in $(seq 1 10); do
			kill -0 "$COMP_PID" 2>/dev/null || break
			sleep 0.1
		done
		kill -KILL "$COMP_PID" 2>/dev/null || true
		wait "$COMP_PID" 2>/dev/null || true
	fi
	rm -f "$SOCKET"
	if [ "$KEEP_LOGS" = "0" ] && [ "$code" = "0" ]; then
		rm -rf "$LOGDIR"
	else
		echo "logs kept at $LOGDIR" >&2
	fi
	exit "$code"
}
# Arm cleanup before anything that can exit (e.g. the rc.lua check below), so
# the temp dir created above is always removed.
trap cleanup EXIT INT TERM

# Use the in-tree minimal rc.lua (no quickshell, no systray). This keeps the
# nested compositor quiet and removes spurious xdg/layer surfaces that would
# otherwise interleave with the disconnect-mid-map clients we are trying to
# stress.
TEST_RC="$ROOT_DIR/tests/rc.lua"
if [ ! -f "$TEST_RC" ]; then
	echo "ERROR: tests/rc.lua not found at $TEST_RC" >&2
	exit 2
fi
TEST_HOME="$LOGDIR/config"
mkdir -p "$TEST_HOME/somewm"
cp "$TEST_RC" "$TEST_HOME/somewm/rc.lua"

# Start nested compositor (wayland backend; this is the same path Steam hit).
SOMEWM_SOCKET="$SOCKET" \
	XDG_CONFIG_HOME="$TEST_HOME" \
	WLR_BACKENDS=wayland \
	WLR_WL_OUTPUTS=1 \
	NO_AT_BRIDGE=1 \
	"$SOMEWM" -d >"$COMP_LOG" 2>&1 &
COMP_PID=$!

# Wait for IPC to come up.
for _ in $(seq 1 100); do
	if [ -S "$SOCKET" ] \
		&& SOMEWM_SOCKET="$SOCKET" "$CLIENT" ping >/dev/null 2>&1; then
		break
	fi
	if ! kill -0 "$COMP_PID" 2>/dev/null; then
		echo "ERROR: compositor died during startup. Log:" >&2
		tail -40 "$COMP_LOG" >&2
		exit 2
	fi
	sleep 0.1
done

if ! SOMEWM_SOCKET="$SOCKET" "$CLIENT" ping >/dev/null 2>&1; then
	echo "ERROR: compositor IPC never came up" >&2
	tail -40 "$COMP_LOG" >&2
	exit 2
fi

# Discover the nested WAYLAND_DISPLAY. somewm-client eval prints "OK" on
# the first line, the Lua return value on the second line, and a trailing
# blank line — so a naive `tail -1` grabs the blank line. Strip empties
# and the leading "OK" before picking the value.
NESTED_DISPLAY=""
for _ in $(seq 1 50); do
	raw=$(SOMEWM_SOCKET="$SOCKET" "$CLIENT" eval \
		'return os.getenv("WAYLAND_DISPLAY") or ""' 2>/dev/null \
		| awk 'NF && $0 != "OK" { print; exit }')
	if [ -n "$raw" ]; then
		NESTED_DISPLAY=$raw
		break
	fi
	sleep 0.1
done
if [ -z "$NESTED_DISPLAY" ]; then
	echo "ERROR: could not discover nested WAYLAND_DISPLAY" >&2
	exit 2
fi

echo "test driver: nested somewm pid=$COMP_PID display=$NESTED_DISPLAY"
echo "test driver: spawning $ITERATIONS disconnect-mid-map clients..."

died_at=""
mapped=0
for i in $(seq 1 "$ITERATIONS"); do
	# Count clients that connected and completed their mapping commit (exit 0),
	# so a run that exercised nothing cannot report PASS (see check below).
	if WAYLAND_DISPLAY="$NESTED_DISPLAY" "$TESTC" >/dev/null 2>&1; then
		mapped=$((mapped + 1))
	fi

	# Brief settle before checking liveness; client closes its fd
	# asynchronously and the compositor needs one more poll cycle to act.
	sleep 0.02

	if ! kill -0 "$COMP_PID" 2>/dev/null; then
		died_at=$i
		break
	fi

	if [ "$ROUND_DELAY" != "0" ]; then
		sleep "$ROUND_DELAY"
	fi

	if (( i % 50 == 0 )); then
		echo "  ... $i iterations, compositor still up"
	fi
done

if [ -n "$died_at" ]; then
	echo "FAIL: compositor crashed after iteration $died_at" >&2
	echo "tail of compositor log:" >&2
	tail -30 "$COMP_LOG" >&2
	# Promote to coredumpctl if available.
	if command -v coredumpctl >/dev/null 2>&1; then
		echo "--- coredumpctl info (this run's somewm, pid=$COMP_PID) ---" >&2
		coredumpctl info "$COMP_PID" 2>&1 | tail -25 >&2 || true
	fi
	exit 1
fi

# Proof of work: if not one client connected and completed its mapping commit,
# the harness exercised nothing and "survived" is meaningless.
if [ "$mapped" -eq 0 ]; then
	echo "ERROR: 0/$ITERATIONS clients connected to the nested compositor;" >&2
	echo "       nothing was mapped, so the disconnect-mid-map path was not tested." >&2
	tail -30 "$COMP_LOG" >&2
	exit 2
fi

# Final liveness probe.
if ! SOMEWM_SOCKET="$SOCKET" "$CLIENT" ping >/dev/null 2>&1; then
	echo "FAIL: compositor stopped responding to IPC after $ITERATIONS iterations" >&2
	tail -30 "$COMP_LOG" >&2
	exit 1
fi

echo "PASS: compositor survived $ITERATIONS disconnect-mid-map iterations ($mapped mapped)"
exit 0
