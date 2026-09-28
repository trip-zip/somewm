#!/usr/bin/env bash
#
# Regression test: absolute pointer motion from a nested (Wayland/X11) backend
# must map to the output the host window belongs to.
#
# Nested backends create one pointer per output, reporting 0..1 within that
# output's host window. Before the fix the cursor mapped it across the whole
# layout, so with two outputs the pointer landed at twice its real x.
#
# Runs a headless "outer" somewm hosting an "inner" somewm on the Wayland
# backend with two outputs, hovers the centre of the inner's second output
# window, and asserts the inner cursor is at the centre of its second screen.
# Needs two compositors, so it is a process-level test rather than Lua/IPC.
#
# Usage: ./tests/test-nested-pointer-mapping.sh [somewm] [somewm-client]

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SOMEWM="$(realpath "${1:-./build-test/somewm}")"
CLIENT="$(realpath "${2:-./build-test/somewm-client}")"

TMP_DIR="$(mktemp -d)"
mkdir -m 700 "$TMP_DIR/runtime"
mkdir -p "$TMP_DIR/config/somewm"
cp "$ROOT_DIR/tests/rc.lua" "$TMP_DIR/config/somewm/rc.lua"

export WLR_RENDERER=pixman
export NO_AT_BRIDGE=1
export XDG_RUNTIME_DIR="$TMP_DIR/runtime"
export XDG_CONFIG_HOME="$TMP_DIR/config"
export LUA_PATH="$ROOT_DIR/lua/?.lua;$ROOT_DIR/lua/?/init.lua;$ROOT_DIR/tests/?.lua;${LUA_PATH:-};"
unset DISPLAY WAYLAND_DISPLAY SOMEWM_SOCKET

OUTER_PID="" INNER_PID=""
cleanup() {
    kill -KILL $INNER_PID $OUTER_PID 2>/dev/null
    rm -rf "$TMP_DIR"
    return 0
}
trap cleanup EXIT INT TERM

fail() {
    echo "--- FAIL: $1"
    for l in outer inner; do
        echo "Last 20 lines of $l log:"
        tail -20 "$TMP_DIR/$l.log" 2>/dev/null | sed 's/^/    /'
    done
    exit 1
}

wait_for() {
    local i
    for i in $(seq 150); do [ -e "$1" ] && return 0; sleep 0.1; done
    fail "timed out waiting for $1"
}

outer() { SOMEWM_SOCKET="$TMP_DIR/outer.sock" "$CLIENT" eval "$1" | sed -n 2p; }
inner() { SOMEWM_SOCKET="$TMP_DIR/inner.sock" "$CLIENT" eval "$1" | sed -n 2p; }

SOMEWM_SOCKET="$TMP_DIR/outer.sock" WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
    "$SOMEWM" >"$TMP_DIR/outer.log" 2>&1 &
OUTER_PID=$!
wait_for "$TMP_DIR/outer.sock"
wait_for "$XDG_RUNTIME_DIR/wayland-0"

SOMEWM_SOCKET="$TMP_DIR/inner.sock" WAYLAND_DISPLAY=wayland-0 WLR_BACKENDS=wayland \
    WLR_WL_OUTPUTS=2 "$SOMEWM" >"$TMP_DIR/inner.log" 2>&1 &
INNER_PID=$!
wait_for "$TMP_DIR/inner.sock"

# Put the inner's output windows side by side (WL-N at x=(N-1)*640) at 640x360.
for i in $(seq 50); do
    [ "$(outer 'return #client.get()')" = 2 ] && break
    sleep 0.1
done
# IPC eval is line-based, so each snippet must be a single line.
outer 'for _, c in ipairs(client.get()) do local n = tonumber(c.name:match("WL%-(%d)")) c.floating = true c:geometry({ x = (n - 1) * 640, y = 0, width = 640, height = 360 }) end' >/dev/null

for i in $(seq 50); do
    [ "$(inner 'return screen[2] and screen[2].geometry.width')" = 640 ] && break
    sleep 0.1
done

# Hover the centre of WL-2's window; route it through real motion handling.
outer 'mouse.coords({ x = 959, y = 180 }) mouse._fake_motion(1, 0)' >/dev/null
sleep 0.5

got="$(inner 'local g = screen[2].geometry local c = mouse.coords() return string.format("%d %d %d", mouse.screen.index, c.x - g.x, g.width)')"
read -r scr x w <<<"$got"
[ "${scr:-}" = 2 ] || fail "inner cursor on screen ${scr:-?}, expected 2 (got: $got)"
[ $(( x - w / 2 )) -ge -3 ] && [ $(( x - w / 2 )) -le 3 ] ||
    fail "inner cursor at x=$x within screen 2, expected ~$(( w / 2 )) (got: $got)"

echo "--- PASS: nested pointer mapped to its own output (screen $scr, x=$x of $w)"
echo "PASS"
exit 0
