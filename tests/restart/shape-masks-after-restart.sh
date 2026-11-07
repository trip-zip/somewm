#!/usr/bin/env bash
. "$(dirname "$0")/lib.sh"
sw_require_helper test-fullscreen-client
CLIENT=$SW_HELPER
sw_start hr-masks --config "$RESTART_DIR/configs/rc-shape-masks.lua" || finish
sw_spawn hr-masks "$CLIENT" || finish
check_client_appeared hr-masks fullscreen_test || finish
SHAPES='for line in awesome._clay_tree(screen[1]):gmatch("[^\n]+") do if line:find("CLIENT ",1,true) and line:find(" shape",1,true) then return "true" end end return "false"'
check_wait_true hr-masks "client declares a path before reload" "$SHAPES" || finish
before_pid=$(sw_pid hr-masks)
for reload in 1 2; do
    sw_reload hr-masks || finish
    check_eval hr-masks "move after reload $reload" \
        'FRAME_BEFORE=awesome._test_frame_count; local c=client.get()[1]; c.x=c.x+10; return "moved"' moved
    check_wait_true hr-masks "frame presented after reload $reload" \
        'return tostring(awesome._test_frame_count > FRAME_BEFORE)' || finish
    check "pid unchanged after reload $reload" "$(sw_pid hr-masks)" "$before_pid"
    check_wait_true hr-masks "client declares a path after reload $reload" "$SHAPES" || finish
done
sw_check_log_clean hr-masks
finish
