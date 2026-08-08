#!/usr/bin/env bash
#
# Proof that a reload closes the old Lua state instead of abandoning it.
#
# double-restart shows the lgi closure population holding steady, which is
# consistent with a close but does not require one. This asserts the close
# itself: the config roots a userdata whose __gc writes a marker, and GC is
# stopped on the old state from the first line of the reload, so the only thing
# that can ever run that finalizer is lua_close().
#
# Two reloads, because one marker could come from process teardown.

. "$(dirname "$0")/lib.sh"

sw_start hr-close --config "$RESTART_DIR/configs/rc-close-probe.lua" || finish

check_eval hr-close "the probe is rooted in the config" \
    'return tostring(CLOSE_PROBE ~= nil)' true
check_log_count hr-close "nothing finalized before the first reload" \
    "CLOSE_PROBE: state finalized" 0

sw_reload hr-close || finish
check_log_count hr-close "the first reload closed the state it replaced" \
    "CLOSE_PROBE: state finalized" 1
check_log hr-close "and says so" "hot-reload: closed old Lua state"

sw_reload hr-close || finish
check_log_count hr-close "so did the second" \
    "CLOSE_PROBE: state finalized" 2

# The rebuilt state has to be a working one, or closing is no achievement.
check_eval hr-close "the rebuilt state re-ran the config" \
    'return tostring(CLOSE_PROBE ~= nil)' true
check_eval hr-close "and still serves the API" 'return tostring(screen.count())' 1

sw_check_log_clean hr-close "post-reload log"

finish
