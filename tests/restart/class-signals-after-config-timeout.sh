#!/usr/bin/env bash
#
# A config timeout must not leave class signal handlers behind.
#
# Class signal arrays live on the C-side lua_class_t, not in the Lua state, so
# they outlive the lua_close() the timeout abort performs. luaA_class_setup
# resets the miss handlers and the instance count when it re-runs in the fresh
# state, but nothing resets `signals`. So a config that connected a class signal
# before hanging leaves handlers that are refs into a closed state, and the very
# next emit of that signal dispatches them: "attempt to call a nil value", from
# luaA_dofunction, with no indication of where it came from.
#
# The hot-reload path already handles this with luaA_class_cleanup_all(); this
# pins the same call on the timeout path.
#
# Any class signal would do. screen's is used because the test can emit it
# directly, with no client or tag to arrange first.

. "$(dirname "$0")/lib.sh"

sw_start_hung_config hr-cls "$ROOT_DIR/tests/rc.lua" hang-class-signal || finish

check_eval hr-cls "the signal the dead config connected can be emitted" \
    'screen.emit_signal("probe::stale"); return "emitted"' emitted

# The handler is gone with the state that owned it, so nothing should run and
# nothing should be dispatched. Both halves matter: a surviving handler would
# print its marker, and a stale ref prints the nil-value error instead.
if log_has hr-cls "STALE HANDLER RAN"; then
    fail "the dead config's handler did not run" "it ran in the fresh state"
else
    pass "the dead config's handler did not run"
fi

if log_has hr-cls "attempt to call a nil value"; then
    fail "no stale class handler was dispatched" \
         "$(grep -F -- "attempt to call a nil value" "$(sw_log hr-cls)" | head -3)"
else
    pass "no stale class handler was dispatched"
fi

# Control: the class signal machinery itself still works in the fresh state, so
# a pass above means the array was cleared and not that emit became a no-op.
check_eval hr-cls "a handler connected after the timeout does run" \
    'HIT = 0; screen.connect_signal("probe::fresh", function() HIT = HIT + 1 end); screen.emit_signal("probe::fresh"); return tostring(HIT)' \
    1

sw_check_log_clean hr-cls "post-timeout log"

finish
