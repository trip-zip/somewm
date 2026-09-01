#!/usr/bin/env bash
#
# awesome.startup is true while a config loads, on a fresh start and on a
# reload alike, and false once the loop is running. awesome._restart is what
# says which of the two it was.

. "$(dirname "$0")/lib.sh"

FLAGS='return tostring(STARTUP_AT_LOAD) .. "/" .. tostring(RESTART_AT_LOAD) .. "/" .. tostring(awesome.startup)'

sw_start hr-startup --config "$RESTART_DIR/configs/startup/rc.lua" || finish

check_eval hr-startup "fresh start: startup true at load, _restart unset, startup false in the loop" \
    "$FLAGS" "true/nil/false"

sw_reload hr-startup || finish

check_eval hr-startup "reload: startup true at load, _restart true, startup false in the loop" \
    "$FLAGS" "true/true/false"

sw_check_log_clean hr-startup "post-reload log"

finish
