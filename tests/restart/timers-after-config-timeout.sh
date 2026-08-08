#!/usr/bin/env bash
#
# After a config timeout, lgi callbacks must still run.
#
# The timeout path sweeps GLib sources, which bumps the lgi closure guard's
# generation. The guard compares generations with == and silently returns zeroed
# memory for anything that does not match, so unless the generation is marked
# ready once the fallback config has loaded, every lgi closure created
# afterwards is dropped. Nothing is logged and no error surfaces anywhere.
#
# Two probes with different consumers, because the failure is not specific to
# timers: a gears.timer tick and an awful.spawn.easy_async completion.
#
# timers-after-restart is the control: the same probes down the reload path,
# which does mark the generation ready.

. "$(dirname "$0")/lib.sh"

sw_start_hung_config hr-t3 || finish

check_timer_fires hr-t3 "gears.timer fires after a config timeout"

check_eval hr-t3 "easy_async armed" \
    'SPAWNED = false; require("awful.spawn").easy_async("true", function() SPAWNED = true end); return "armed"' \
    armed
if sw_wait_true hr-t3 'return tostring(SPAWNED == true)' 5; then
    pass "awful.spawn.easy_async completes after a config timeout"
else
    fail "awful.spawn.easy_async completes after a config timeout" "callback never ran"
fi

# Informational. The fix is asserted through the timer probes above, not
# through guard log lines, so this block never fails the test.
if log_has hr-t3 "lgi_guard: bumped to generation"; then
    if log_has hr-t3 "marked ready"; then
        info "guard generation was marked ready"
    else
        info "guard generation was bumped but never marked ready"
    fi
fi

sw_check_log_clean hr-t3

finish
