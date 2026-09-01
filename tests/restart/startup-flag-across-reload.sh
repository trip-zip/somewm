#!/usr/bin/env bash
#
# awesome.startup tells a config whether this is a fresh start or a reload.
#
# somewm --check points configs at it as the replacement for the X11 restart
# probe built from awesome.get_xproperty, which is not bound here. That advice
# only holds while the flag reads true during a fresh start's config load and
# false during a reload's, so pin both.

. "$(dirname "$0")/lib.sh"

sw_start hr-startup --config "$RESTART_DIR/configs/startup/rc.lua" || finish

check_eval hr-startup "a fresh start loads its config with startup true" \
    'return tostring(STARTUP_AT_LOAD)' true
check_eval hr-startup "and the flag is false once the loop is running" \
    'return tostring(awesome.startup)' false

sw_reload hr-startup || finish

check_eval hr-startup "a reload loads its config with startup false" \
    'return tostring(STARTUP_AT_LOAD)' false

sw_check_log_clean hr-startup "post-reload log"

finish
