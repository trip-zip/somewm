#!/usr/bin/env bash
#
# "exit" reaches one state twice, and the timer release has to survive it.
#
# A reload emits "exit" and then quits if a later phase fails, and the quit runs
# cleanup(), which emits "exit" again on the same still-open state. The release
# in gears/timer.lua nils each timer's source id; if it leaves the timer in its
# registry, the second pass calls glib.source_remove(nil) and lgi throws from
# inside an exit handler, taking the rest of the release with it.
#
# Emitting the signal directly is the whole repro. It needs no allocation
# failure to reach the second emission, and it is the same entry point both
# emitters use.

. "$(dirname "$0")/lib.sh"

sw_start hr-tx || finish

check_eval hr-tx "timer armed" "$TIMER_ARM" armed

check_eval hr-tx "\"exit\" emitted twice on one state" \
    'awesome.emit_signal("exit", true); awesome.emit_signal("exit", true); return "twice"' \
    twice

# The emit is protected, so a throwing handler shows up in the log and nowhere
# else. Both needles: the argument error itself, and the error handler that
# reports whatever else the second pass might throw.
for needle in "source_remove" "Error during"; do
    if log_has hr-tx "$needle"; then
        fail "the second \"exit\" throws nothing ($needle)" \
             "$(grep -F -- "$needle" "$(sw_log hr-tx)" | head -3)"
    else
        pass "the second \"exit\" throws nothing ($needle)"
    fi
done

sw_check_log_clean hr-tx

finish
