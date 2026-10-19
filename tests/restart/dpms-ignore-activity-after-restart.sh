#!/usr/bin/env bash
# A fresh Lua configuration starts with activity-driven display wakeups enabled,
# even when the previous configuration disabled them before awesome.restart().

. "$(dirname "$0")/lib.sh"

sw_start hr-dpms --config "$ROOT_DIR/tests/rc.lua" || finish

check_eval hr-dpms "activity wakeups enabled at startup" \
    'return tostring(awesome.dpms_ignore_activity)' false

check_eval hr-dpms "activity wakeups can be disabled" \
    'awesome.dpms_ignore_activity = true; return tostring(awesome.dpms_ignore_activity)' true

sw_reload hr-dpms || finish

check_eval hr-dpms "reload resets the activity setting" \
    'return tostring(awesome.dpms_ignore_activity)' false

sw_check_log_clean hr-dpms "post-reload log"

finish
