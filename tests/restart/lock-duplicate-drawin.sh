#!/usr/bin/env bash
# One wibox may be both a lock cover and the lock surface. Rendering it must
# leave the instance serving IPC rather than aborting on a duplicate Clay id.

. "$(dirname "$0")/lib.sh"

sw_start hr-lock-duplicate --config "$ROOT_DIR/tests/rc.lua" || finish

check_eval hr-lock-duplicate "one wibox registers in both lock roles" \
    'LOCKW = require("wibox")({ width=10, height=10, visible=true }); awesome.set_lock_surface(LOCKW); awesome.add_lock_cover(LOCKW); return tostring(awesome.lock_surface ~= nil)' true
check_eval hr-lock-duplicate "the instance locks" \
    'FRAME_BEFORE = awesome._test_frame_count; return tostring(awesome.lock())' true
check_wait_true hr-lock-duplicate "a frame is presented while locked" \
    'return tostring(awesome.locked and awesome._test_frame_count > FRAME_BEFORE)' || finish
check_eval hr-lock-duplicate "instance serves IPC after the locked frame" \
    'return 1+1' 2

sw_check_log_clean hr-lock-duplicate "locked frame log"

finish
