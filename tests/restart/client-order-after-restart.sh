#!/usr/bin/env bash
# Manage order and client sibling order survive a hot reload independently.

. "$(dirname "$0")/lib.sh"

sw_require_helper test-fullscreen-client
CLIENT=$SW_HELPER

sw_start hr-order --config "$ROOT_DIR/tests/rc.lua" || finish

sw_spawn hr-order "$CLIENT" || finish
pid_a=$SPAWN_PID
check_client_appeared hr-order fullscreen_test || finish

sw_spawn hr-order "$CLIENT" || finish
pid_b=$SPAWN_PID
sw_wait_true hr-order "return tostring(#client.get() == 2)" 10

check "two distinct clients spawned" "$([ "$pid_a" != "$pid_b" ] && echo yes || echo no)" yes

ORDER='local t = {}; for _, c in ipairs(client.get()) do t[#t+1] = tostring(c.pid) end; return table.concat(t, ",")'

sw_eval hr-order "$ORDER"
before=$EVAL_VALUE
info "phase-1 order: $before"
check_match "phase-1 order lists both clients" "$before" "^[0-9]+,[0-9]+$"

check_eval hr-order "raise the older client" "local c = client.get(); for _, v in ipairs(c) do if v.pid == $pid_a then v:raise(); return true end end" true
STACK='local t = {}; for _, c in ipairs(client.get(nil, true)) do t[#t+1] = tostring(c.pid) end; return table.concat(t, ",")'
sw_eval hr-order "$STACK"
stack_before=$EVAL_VALUE
check "raised client is first in stacking order" "$stack_before" "$pid_a,$pid_b"

sw_reload hr-order || finish

check_eval hr-order "client.get() order is unchanged across the reload" "$ORDER" "$before"

check_eval hr-order "raised client remains on top after reload" "$STACK" "$stack_before"

sw_check_log_clean hr-order "post-reload log"

finish
