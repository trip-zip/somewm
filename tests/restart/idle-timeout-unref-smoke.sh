#!/usr/bin/env bash
#
# Clearing idle timeouts after a hot-reload must not corrupt the new registry.
#
# idle_timeouts[] keeps registry refs from the old state, and the wl timers keep
# firing into the new one. awesome.clear_all_idle_timeouts (exposed to rc.lua)
# then luaL_unrefs those old-state refs against the new state's registry, which
# frees whatever live slot happens to sit at each index.
#
# This is the memory-corrupting class, so the symptoms are arbitrary and
# delayed; nobody would ever notice it without poking it deliberately. The
# smoke test is crude on purpose: clear the timeouts, then check that ordinary
# machinery still works, exercised rather than merely traced.

# xfail: idle_timeouts[] unrefs old-state refs against the new registry, freeing unrelated live slots

. "$(dirname "$0")/lib.sh"

sw_start hr-idle --config "$ROOT_DIR/tests/rc.lua" || finish

check_eval hr-idle "an idle timeout can be armed before the reload" \
    'awesome.set_idle_timeout("restart-probe", 3600, function() end); return "armed"' armed

sw_reload hr-idle || finish

# Re-arm in the new state too, so the array holds a mix of old and new refs:
# that is the arrangement a real config produces.
check_eval hr-idle "an idle timeout can be armed after the reload" \
    'awesome.set_idle_timeout("restart-probe-2", 3600, function() end); return "armed"' armed

check_eval hr-idle "clearing idle timeouts does not error" \
    'return tostring(pcall(awesome.clear_all_idle_timeouts))' true

# If the unref freed a live slot, what breaks is arbitrary and later. Poke the
# machinery most likely to be holding registry refs.
check_timer_fires hr-idle "a timer armed after the clear fires"
check_eval hr-idle "idle timeouts can be armed again after the clear" \
    'awesome.set_idle_timeout("restart-probe-3", 3600, function() end); return "armed"' armed

sw_check_log_clean hr-idle "post-clear log"

finish
