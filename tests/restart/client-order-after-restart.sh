#!/usr/bin/env bash
#
# client.get() order must be identical across a hot-reload.
#
# This is the regression test for the Phase E fix that used client_array_append
# instead of client_array_push to stop globalconf.clients reversing.
# tests/test-hot-reload-client-order.lua named that fix but only printed the
# pre-restart order and asserted nothing afterwards, so the guard has never
# actually run.
#
# Both helpers share one app_id, so order by pid.

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

sw_reload hr-order || finish

check_eval hr-order "client.get() order is unchanged across the reload" "$ORDER" "$before"

sw_check_log_clean hr-order "post-reload log"

finish
