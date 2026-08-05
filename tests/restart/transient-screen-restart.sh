#!/usr/bin/env bash
#
# A transient that sits before its parent in client.get() must survive a
# hot-reload, with its transient_for link intact.
#
# Replaces tests/test-hot-reload-transient-screen.lua, which set up exactly this
# arrangement (the Phase F crash needed the transient to be dereferenced before
# its parent had a screen), asserted the precondition, then called
# awesome.restart() and finished. The crash it guards is only observable after
# the reload, which that test never reached.
#
# The pid is kept on the shell side so it stays usable after the reload.

. "$(dirname "$0")/lib.sh"

sw_require_helper test-transient-client
CLIENT=$SW_HELPER

sw_start hr-tr --config "$ROOT_DIR/tests/rc.lua" || finish

sw_spawn hr-tr "$CLIENT" || finish
helper_pid=$SPAWN_PID
check_client_appeared hr-tr transient_test_parent || finish

# SIGUSR1 tells the helper to map the transient.
kill -USR1 "$helper_pid" 2>/dev/null || { fail "signalled the helper"; finish; }
check_client_appeared hr-tr transient_test_child || finish

POS='local pi, ci; for i, c in ipairs(client.get()) do if c.class == "transient_test_parent" then pi = i end; if c.class == "transient_test_child" then ci = i end end; return tostring(ci) .. "<" .. tostring(pi)'

sw_eval hr-tr "$POS"
before_pos=$EVAL_VALUE
info "phase-1 child<parent index: $before_pos"

# The bug repro needs the transient first; if the order came out the other way
# the test is not exercising what it claims to.
sw_eval hr-tr 'local pi, ci; for i, c in ipairs(client.get()) do if c.class == "transient_test_parent" then pi = i end; if c.class == "transient_test_child" then ci = i end end; return tostring(ci ~= nil and pi ~= nil and ci < pi)'
check "transient precedes its parent in client.get()" "$EVAL_VALUE" true

check_eval hr-tr "the parent has a screen before the reload" \
    'for _, c in ipairs(client.get()) do if c.class == "transient_test_parent" then return tostring(c.screen ~= nil) end end; return "no parent"' true

sw_reload hr-tr || finish

check_eval hr-tr "both clients survive the reload" 'return tostring(#client.get())' 2
check_eval hr-tr "the ordering relationship is preserved" "$POS" "$before_pos"
check_eval hr-tr "transient_for still resolves to the parent" \
    'for _, c in ipairs(client.get()) do if c.class == "transient_test_child" then return tostring(c.transient_for ~= nil and c.transient_for.class) end end; return "no child"' \
    transient_test_parent

sw_check_log_clean hr-tr "post-reload log"

finish
