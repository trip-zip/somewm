#!/usr/bin/env bash
# A hidden wibox still holding shape refs is collected by lua_close() on reload.

. "$(dirname "$0")/lib.sh"

sw_start hr-hidden --config "$RESTART_DIR/configs/rc-hidden-drawin-shape.lua" || finish
SHAPES='return tostring(awesome._clay_tree(screen[1]):find(" shape", 1, true) ~= nil)'
check_wait_true hr-hidden "visible wibox declares a shape" "$SHAPES" || finish
check_eval hr-hidden "hide the wibox" 'hidden_popup.visible = false; return "hidden"' hidden
before_pid=$(sw_pid hr-hidden)
sw_reload hr-hidden || finish
check "pid unchanged after reload" "$(sw_pid hr-hidden)" "$before_pid"
check_eval hr-hidden "instance serves IPC after reload" 'return 1+1' 2
sw_check_log_clean hr-hidden
finish
