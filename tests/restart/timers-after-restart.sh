#!/usr/bin/env bash
#
# gears.timer must still fire after a hot-reload.
#
# Timers are GLib timeouts driven by lgi ffi closures, and the reload bumps the
# closure guard's generation, blocking every closure until
# lgi_guard_mark_ready() runs at the end of luaA_hot_reload. A blocked closure
# returns zeroed memory silently, so the only way to see this is to arm a real
# timer and watch for the tick.
#
# This is also the control for timers-after-config-timeout, which runs the same
# probe down the path that never marks the generation ready.

. "$(dirname "$0")/lib.sh"

sw_start hr-timer --config "$ROOT_DIR/tests/rc.lua" || finish

# Baseline first: a probe that cannot fire before the reload would make the
# post-reload result meaningless.
check_timer_fires hr-timer "a timer fires before the reload" || finish

sw_reload hr-timer || finish

check_timer_fires hr-timer "a timer fires after the reload"

# Not a barrier for the harness, but on a build with the LD_PRELOAD guard this
# is the line that explains why the timer worked.
if log_has hr-timer "lgi_guard: bumped to generation"; then
    check_log hr-timer "the closure guard was marked ready" \
        "lgi_guard: generation 1 marked ready"
else
    info "closure guard not preloaded, skipping its log assertion"
fi

sw_check_log_clean hr-timer "post-reload log"

finish
