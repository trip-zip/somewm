#!/usr/bin/env bash
#
# Two reloads in a row, and the closure census that documents the per-reload leak.
#
# Surviving twice matters on its own: the second reload runs against a state
# that was itself rebuilt, and the source sweep ratchets its baseline each time,
# so anything created between reloads is in range of the next sweep.
#
# The census half pins the leak itself. Each reload leaks the old Lua state with GC
# stopped, along with every lgi closure wrapper ever created, so the wrapped
# count roughly doubles per reload and nothing is ever freed. It is expected to
# fail until the reload either closes the old state or documents a fallback.

# xfail: every reload leaks the old Lua state and its lgi closures; the wrapped count only grows

. "$(dirname "$0")/lib.sh"

sw_start hr-double --config "$ROOT_DIR/tests/rc.lua" || finish

STATE='return tostring(screen.count()) .. "," .. tostring(#client.get()) .. "," .. tostring(#screen.primary.tags)'

sw_eval hr-double "$STATE"
before=$EVAL_VALUE
info "phase-1 screens,clients,tags = $before"

before_pid=$(sw_pid hr-double)

sw_reload hr-double || finish
sw_reload hr-double || finish
check_eval hr-double "screens, clients and tags unchanged after two reloads" "$STATE" "$before"
check "pid unchanged after two reloads" "$(sw_pid hr-double)" "$before_pid"
check_log_count hr-double "two completed reloads in the log" "hot-reload: complete" 2

# The sweep count per reload, printed every run: the exit teardown contract
# holding is exactly this number going to zero.
sw_report_sweep hr-double

# Closure census. Note the counters are process-cumulative atomics that never
# reset, and `blocked` on reload N's line is reload N-1's count, so with two
# reloads only the first reload's blocked figure is observable.
if log_has hr-double "lgi_guard: bumped to generation"; then
    wrapped=$(grep -oE 'lgi_guard: bumped to generation [0-9]+ \(wrapped [0-9]+/[0-9]+, blocked [0-9]+\)' \
        "$(sw_log hr-double)" | sed -E 's/.*wrapped ([0-9]+)\/.*/\1/')
    info "wrapped closure counts per reload: $(echo "$wrapped" | tr '\n' ' ')"
    w1=$(echo "$wrapped" | sed -n 1p)
    w2=$(echo "$wrapped" | sed -n 2p)
    if [ -n "$w1" ] && [ -n "$w2" ]; then
        if [ "$w2" -le "$w1" ]; then
            pass "lgi closure population does not grow across reloads ($w1 -> $w2)"
        else
            fail "lgi closure population does not grow across reloads" \
                 "$w1 -> $w2; every closure ever wrapped is still alive"
        fi
    else
        fail "two closure-guard generation bumps recorded" "got: $wrapped"
    fi
else
    # Informational, not a skip: the reload assertions above have already run,
    # and discarding them because the LD_PRELOAD guard is absent would throw
    # away a good result for an unrelated reason.
    info "closure guard not preloaded, cannot census closures"
fi

sw_check_log_clean hr-double "post-reload log"

finish
