#!/usr/bin/env bash
#
# A client made floating stays floating across a hot-reload. The flag lives in
# Lua (awful.client.property), so the state close takes it, and on a tiled tag
# the client comes back tiled unless the reload puts it back.

. "$(dirname "$0")/lib.sh"

sw_require_helper test-fullscreen-client
CLIENT=$SW_HELPER

sw_start hr-floating --config "$ROOT_DIR/tests/rc.lua" || finish

check_eval hr-floating "the tag is tiled" \
    'local t = screen.primary.tags[1]; t.layout = require("awful").layout.suit.tile; return t.layout.name' \
    tile

sw_spawn hr-floating "$CLIENT" || finish
check_client_appeared hr-floating fullscreen_test || finish

check_eval hr-floating "the client is floating" \
    'client.get()[1].floating = true; return tostring(client.get()[1].floating)' true

sw_reload hr-floating || finish

check_eval hr-floating "the client is still floating after the reload" \
    'return tostring(client.get()[1].floating)' true

sw_check_log_clean hr-floating "post-reload log"

finish
