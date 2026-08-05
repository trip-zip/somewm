#!/usr/bin/env bash
#
# A managed client must come back from a hot-reload as the same client.
#
# Replaces tests/test-hot-reload-basic.lua, which spawned a client, called
# awesome.restart() and then asserted nothing (and never reached the reload at
# all). Clients are the one subsystem with a complete detach/snapshot/re-point/
# re-register cycle, so this is the test that proves that machinery works.

. "$(dirname "$0")/lib.sh"

sw_require_helper test-fullscreen-client
CLIENT=$SW_HELPER

sw_start hr-client --config "$ROOT_DIR/tests/rc.lua" || finish

sw_spawn hr-client "$CLIENT" || finish
check_client_appeared hr-client fullscreen_test || finish

IDENT='local t = {}; for _, c in ipairs(client.get()) do local g = c:geometry(); t[#t+1] = c.class .. ":" .. tostring(c.pid) .. ":" .. g.x .. "," .. g.y .. "," .. g.width .. "," .. g.height .. ":" .. tostring(c.screen.index) end; return table.concat(t, "|")'

sw_eval hr-client "$IDENT"
before=$EVAL_VALUE
info "phase-1 identity: $before"
check_match "phase-1 identity is a real client" "$before" '^fullscreen_test:[0-9]+:'

sw_reload hr-client || finish

check_eval hr-client "class, pid, geometry and screen survive the reload" "$IDENT" "$before"
check_eval hr-client "exactly one client after the reload" \
    'return tostring(#client.get())' 1
check_eval hr-client "the restored client is a live object" \
    'return tostring(client.get()[1].valid)' true

sw_check_log_clean hr-client "post-reload log"

finish
