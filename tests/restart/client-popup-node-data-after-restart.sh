#!/usr/bin/env bash
#
# Every scene node carrying a back-pointer to a client must name the client_t
# the current Lua state owns.
#
# A hot-reload frees every client_t and builds new ones. clients_restore() used
# to re-point only Client::scene and Client::scene_surface, leaving
# Client::popups and the four border rects aimed at the freed userdata.
# xytonode() walks a hit node's ancestors reading node.data, so the first
# pointer motion over an open popup read through freed memory and took the
# session down with it.
#
# The popup is the reachable half. It is the only stale node that is ever an
# ancestor of a hit-testable buffer: the borders are siblings of the content
# tree, and xytonode skips non-buffer hits, so they never enter the walk.
#
# What this asserts is the misresolution, not the crash. Whether the stale read
# faults depends on whether the freed Lua arena has been returned to the OS,
# which one reload in a sandbox will not do. The pointer is equally wrong
# either way, so the popup failing to resolve to its client is the reliable
# signal and the segfault is the same defect on a longer-lived session.

. "$(dirname "$0")/lib.sh"

sw_require_helper test-popup-client
CLIENT=$SW_HELPER

sw_start hr-popup --config "$ROOT_DIR/tests/rc.lua" || finish

sw_spawn hr-popup "$CLIENT" || finish
check_client_appeared hr-popup popup_test || finish

# Float and place it, so the popup anchored off its bottom-right corner lands
# somewhere the test can aim at.
PLACE='local c; for _, x in ipairs(client.get()) do if x.class == "popup_test" then c = x end end; if not c then return "no client" end; c.floating = true; c:geometry({x = 100, y = 100, width = 300, height = 300}); local g = c:geometry(); return g.x .. "," .. g.y .. "," .. g.width .. "," .. g.height'

check_eval hr-popup "the client can be placed before the reload" "$PLACE" 100,100,300,300

sw_reload hr-popup || finish

check_eval hr-popup "the client survives the reload" \
    'return tostring(#client.get())' 1
check_eval hr-popup "the client can be placed after the reload" "$PLACE" 100,100,300,300

# The popup maps under Client::popups, the tree whose back-pointer the reload
# used to miss.
if kill -USR1 "$SPAWN_PID" 2>/dev/null; then
    pass "signalled the client to open its popup"
else
    fail "signalled the client to open its popup" "kill -USR1 $SPAWN_PID failed"
    finish
fi

deadline=$((SECONDS + 10))
while [ "$SECONDS" -lt "$deadline" ]; do
    log_has hr-popup "popup configured" && break
    sleep 0.2
done
if log_has hr-popup "popup configured"; then
    pass "the popup mapped"
else
    fail "the popup mapped" "no popup configure logged after 10s"
    finish
fi

# mouse::move carries whatever xytonode() resolved the pointer to, which is the
# read that crashed. mouse.current_client is no use here: it geometry-scans
# globalconf.clients and never walks the scene graph at all.
ARM='local c; for _, x in ipairs(client.get()) do if x.class == "popup_test" then c = x end end; if not c then return "no client" end; _G.HIT = "none"; c:connect_signal("mouse::move", function(cc) _G.HIT = cc.class end); return "armed"'

# Sent twice: the first motion only establishes the cursor position.
move_to() {
    printf 'root.fake_input("motion_notify", false, %s, %s); root.fake_input("motion_notify", false, %s, %s); return "moved"' \
        "$1" "$2" "$1" "$2"
}

check_eval hr-popup "a mouse::move probe can be armed" "$ARM" armed

# Over the client's own content first. This resolves through Client::scene_surface,
# which the reload always re-pointed correctly, so it proves the probe works
# before the interesting case relies on it.
check_eval hr-popup "pointer motion over the client content" \
    "$(move_to 200 200)" moved
check_eval hr-popup "the content resolves to its client" \
    'return tostring(_G.HIT)' popup_test

# Now the popup, which hangs off the parent's bottom-right corner and so covers
# screen the content does not. This is the walk that reached Client::popups.
check_eval hr-popup "the probe can be re-armed" \
    '_G.HIT = "none"; return tostring(_G.HIT)' none
check_eval hr-popup "pointer motion over the popup" \
    "$(move_to 450 450)" moved
check_eval hr-popup "the popup resolves to its own client" \
    'return tostring(_G.HIT)' popup_test

sw_check_log_clean hr-popup "post-motion log"

finish
