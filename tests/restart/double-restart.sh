#!/usr/bin/env bash
#
# Two reloads in a row, and the closure census that pins the per-reload leak.
#
# Surviving twice matters on its own: the second reload runs against a state
# that was itself rebuilt, and the source sweep ratchets its baseline each time,
# so anything created between reloads is in range of the next sweep.
#
# The census half pins the leak itself. Every reload used to leak the old state with
# GC stopped and every lgi closure with it, so the population grew by a full set
# per reload. Now the state is closed, and the live count has to hold steady.

. "$(dirname "$0")/lib.sh"

sw_start hr-double --config "$ROOT_DIR/tests/rc.lua" || finish

STATE='return tostring(screen.count()) .. "," .. tostring(#client.get()) .. "," .. tostring(#screen.primary.tags)'

sw_eval hr-double "$STATE"
before=$EVAL_VALUE
info "phase-1 screens,clients,tags = $before"

before_pid=$(sw_pid hr-double)

# Three, so the cumulative creation count is comfortably clear of one state's
# worth of closures by the time the census below reads it.
sw_reload hr-double || finish
sw_reload hr-double || finish
sw_reload hr-double || finish
check_eval hr-double "screens, clients and tags unchanged after three reloads" "$STATE" "$before"
check "pid unchanged after three reloads" "$(sw_pid hr-double)" "$before_pid"
check_log_count hr-double "three completed reloads in the log" "hot-reload: complete" 3

# The sweep is a backstop now, and should have found nothing to remove on any of
# the three reloads. Asserted by sw_check_log_clean at the end.
sw_report_sweep hr-double

# Closure census, from the last generation bump. `wrapped` counts every closure
# ever created, across every state; `live` counts the ones not yet freed. A
# state that is abandoned frees none of its own, so live tracks wrapped and both
# grow by a set per reload. A state that is closed leaves at most the current
# state's set alive while wrapped keeps counting, so live falls well below it.
#
# Deliberately not a comparison of live counts between reloads: a state whose
# asynchronous D-Bus setup had not finished when the reload landed has three
# fewer closures than one that had, which is a few runs in ten and says nothing
# about leaking.
wrapped=$(sw_census_field hr-double wrapped)
live=$(sw_census_field hr-double live)
if [ -n "$wrapped" ] && [ -n "$live" ]; then
    info "closures at the last reload: wrapped $wrapped, live $live"
    if [ $((live * 2)) -lt "$wrapped" ]; then
        pass "closed states released their lgi closures ($live live of $wrapped created)"
    else
        fail "closed states released their lgi closures" \
             "$live of $wrapped closures still alive; a state's set outlived it"
    fi
else
    # Informational, not a skip: the reload assertions above have already run,
    # and discarding them because the LD_PRELOAD guard is absent would throw
    # away a good result for an unrelated reason. sw_check_log_clean below is
    # the half that does not need the guard.
    info "closure guard not preloaded, cannot census closures"
fi

sw_check_log_clean hr-double "post-reload log"

finish
