#!/usr/bin/env bash
# A client's persistent floating property survives the Lua state rebuild.

. "$(dirname "$0")/lib.sh"

sw_require_helper test-fullscreen-client
CLIENT=$SW_HELPER

sw_start hr-floating --config "$ROOT_DIR/tests/rc.lua" || finish
sw_spawn hr-floating "$CLIENT" || finish
check_client_appeared hr-floating fullscreen_test || finish

check_eval hr-floating "floating is true before reload" \
    'local c = client.get()[1]; c.floating = true; return tostring(c.floating)' true

sw_reload hr-floating || finish

check_eval hr-floating "floating is true after reload" \
    'return tostring(client.get()[1].floating)' true

sw_check_log_clean hr-floating "post-reload log"

finish
