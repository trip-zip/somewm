#!/usr/bin/env bash
#
# A timer armed while the config loads must be released when the state closes.
#
# Getting this wrong crashes rather than leaks: reverting the gears.timer
# release segfaults this test inside libffi under g_timeout_dispatch, which is
# somewm issue 465 (see luaA_cleanup_stale_glib_sources in luaa.c for why the
# closure guard cannot catch it).
#
# The assertions are the warnings, not the crash. A callback that outlives its
# state prints every run; the segfault needs the timeout to come due at the
# wrong moment.

. "$(dirname "$0")/lib.sh"

sw_start hr-boottimer --config "$RESTART_DIR/configs/rc-boot-timer.lua" || finish

check_wait_true hr-boottimer "the config's timer ticks before any reload" \
    'return tostring(BOOT_TICKS >= 2)' 5 || finish

sw_reload hr-boottimer || finish

# A rebuilt state arms its own timer, so ticks say nothing about the old one.
# This is here for the opposite reason: to prove the fix does not stop timers
# the new config wants.
check_wait_true hr-boottimer "the rebuilt config's timer ticks too" \
    'return tostring(BOOT_TICKS >= 2)' 5

sw_reload hr-boottimer || finish

# Cumulative across the process, so the last census covers both reloads. Zero
# either means nothing stale was ever dispatched, or that the guard never got
# the chance: a freed cif kills the process inside libffi first.
blocked=$(sw_census_field hr-boottimer blocked)
if [ -n "$blocked" ]; then
    check "the guard blocked no callback from a closed state" "$blocked" 0
else
    info "closure guard not preloaded, cannot read its blocked count"
fi

sw_report_sweep hr-boottimer

# Carries the assertion: sw_check_log_clean fails on the warning either a
# surviving GLib source or a surviving closure prints.
sw_check_log_clean hr-boottimer "post-reload log"

finish
