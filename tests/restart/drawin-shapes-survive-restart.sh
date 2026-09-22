#!/usr/bin/env bash
# Shape closures and retained client nodes must survive repeated state rebuilds.

. "$(dirname "$0")/lib.sh"

sw_require_helper test-fullscreen-client
CLIENT=$SW_HELPER
sw_require_helper test-transient-client
TRANSIENT_CLIENT=$SW_HELPER
sw_start hr-shapes --config "$RESTART_DIR/configs/rc-drawin-shapes.lua" || finish
sw_spawn hr-shapes "$CLIENT" || finish
check_client_appeared hr-shapes fullscreen_test || finish
sw_spawn hr-shapes "$TRANSIENT_CLIENT" || finish
helper_pid=$SPAWN_PID
check_client_appeared hr-shapes transient_test_parent || finish
kill -USR1 "$helper_pid" 2>/dev/null || { fail "signalled the helper"; finish; }
check_client_appeared hr-shapes transient_test_child || finish

SHAPES='return tostring(awesome._clay_tree(screen[1]):find(" shape", 1, true) ~= nil)'
check_wait_true hr-shapes "tree dump contains a shape leaf before reload" "$SHAPES" || finish
check_wait_true hr-shapes "tree dump contains the mapped client" \
    'return tostring(awesome._clay_tree(screen[1]):find("fullscreen_test", 1, true) ~= nil)' || finish
sw_eval hr-shapes 'return awesome._clay_tree(screen[1])'
info "tree before reload: $EVAL_VALUE"
before_pid=$(sw_pid hr-shapes)

for reload in 1 2; do
    sw_reload hr-shapes || finish
    check_eval hr-shapes "drive a frame after reload $reload" \
        'FRAME_BEFORE = awesome._test_frame_count; local c = client.get()[1]; c.x = c.x + 10; return "moved"' moved
    check_wait_true hr-shapes "a frame was presented after reload $reload" \
        'return tostring(awesome._test_frame_count > FRAME_BEFORE)' || finish
    check "pid unchanged after reload $reload" "$(sw_pid hr-shapes)" "$before_pid"
    check_eval hr-shapes "instance serves IPC after the frame" 'return 1+1' 2
    check_wait_true hr-shapes "tree dump contains a shape leaf after reload" "$SHAPES" || finish
done
sw_check_log_clean hr-shapes
finish
