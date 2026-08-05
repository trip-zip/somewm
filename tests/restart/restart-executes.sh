#!/usr/bin/env bash
#
# The suite's own self-check: prove that awesome.restart() actually runs a
# hot-reload, and that what comes back is a genuinely new Lua state.
#
# This is what the four old tests/test-hot-reload-*.lua tests were supposed to
# do. They never did: awesome.restart() only queues a GLib idle, and their
# runner.done() called awesome.quit() in the same dispatch, so the loop exited
# before the idle ran. Every restart test in this directory depends on this one
# being honest.

. "$(dirname "$0")/lib.sh"

sw_start hr-exec --config "$ROOT_DIR/tests/rc.lua" || finish

check_eval hr-exec "no _restart flag on a cold start" \
    'return tostring(awesome._restart)' nil

# A global in the old state. If it survives, we did not get a new state.
check_eval hr-exec "phase-1 global set" \
    'PHASE1_WITNESS = "alive"; return PHASE1_WITNESS' alive

sw_eval hr-exec 'return tostring(screen.count()) .. "," .. tostring(#client.get())'
before_counts=$EVAL_VALUE
info "phase-1 screens,clients = $before_counts"

before_pid=$(sw_pid hr-exec)

sw_reload hr-exec || finish

# The assertion that proves the reload ran. _restart alone proves nothing about the Lua state
# being rebuilt; a wiped global does.
check_eval hr-exec "phase-1 global is gone (state was rebuilt, not just flagged)" \
    'return tostring(PHASE1_WITNESS)' nil

check_eval hr-exec "screen and client counts unchanged" \
    'return tostring(screen.count()) .. "," .. tostring(#client.get())' "$before_counts"

check "pid unchanged (in-process rebuild, not a respawn)" "$(sw_pid hr-exec)" "$before_pid"

check_log hr-exec "log records the rebuild starting" \
    "hot-reload: starting in-process Lua state rebuild"
check_log_count hr-exec "log records exactly one completed reload" \
    "hot-reload: complete" 1

sw_check_log_clean hr-exec "post-reload log"

finish
