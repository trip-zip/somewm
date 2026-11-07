#!/usr/bin/env bash

. "$(dirname "$0")/lib.sh"

sw_require_helper test-fullscreen-client
CLIENT=$SW_HELPER
box=$(sw_sandbox)
cp "$RESTART_DIR/configs/rc-client-shape.lua" "$box/rc.lua"

sw_start hr-client-shape --config "$box/rc.lua" || finish
sw_spawn hr-client-shape "$CLIENT" || finish
client_pid=$SPAWN_PID
check_client_appeared hr-client-shape fullscreen_test || finish
before_pid=$(sw_pid hr-client-shape)

FIND_CLIENT="local c; for _, v in ipairs(client.get()) do if v.pid == $client_pid then c = v end end; assert(c and c.valid, 'client missing or invalid'); "
check_eval hr-client-shape "client has a shape function before reload" \
    "${FIND_CLIENT}return type(c.shape)" function

for reload in 1 2; do
    sw_reload hr-client-shape || finish
    check "pid unchanged after reload $reload" "$(sw_pid hr-client-shape)" "$before_pid"
    check_eval hr-client-shape "client remains valid after reload $reload" \
        "${FIND_CLIENT}return tostring(c.valid)" true
    check_eval hr-client-shape "rule reapplies the shape function after reload $reload" \
        "${FIND_CLIENT}return type(c.shape)" function

    if [ "$reload" = 1 ]; then
        SHAPE="function(cr, w, h) require('gears').shape.rounded_rect(cr, w, h, 6) end"
        check_eval hr-client-shape "replace the shape function" \
            "${FIND_CLIENT}c.shape = $SHAPE; return type(c.shape)" function
        check_eval hr-client-shape "clear the shape function" \
            "${FIND_CLIENT}c.shape = nil; return type(c.shape)" nil
        check_eval hr-client-shape "set the shape function again" \
            "${FIND_CLIENT}c.shape = $SHAPE; return type(c.shape)" function
    fi
done

sw_check_log_clean hr-client-shape "post-reload log"
finish
