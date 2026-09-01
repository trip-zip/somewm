#!/usr/bin/env bash
#
# A client on a screen the mouse is not on stays there across a hot-reload.
# The default config's screen rule is awful.screen.preferred, which keeps
# c.screen only while awesome.startup reads true.

. "$(dirname "$0")/lib.sh"

sw_require_helper test-fullscreen-client
CLIENT=$SW_HELPER

sw_start hr-screen --config "$RESTART_DIR/configs/preferred-screen/rc.lua" || finish

sw_eval hr-screen 'awesome._test_add_output(800, 600)'
check_wait_true hr-screen "a second screen exists" 'return tostring(screen.count() == 2)' || finish

sw_spawn hr-screen "$CLIENT" || finish
check_client_appeared hr-screen fullscreen_test || finish

# Assign the screen directly: move_to_screen drags the mouse along with the
# client, and the whole point is that the mouse is on the other screen.
check_eval hr-screen "the client is on screen 2 and the mouse on screen 1" \
    'client.get()[1].screen = screen[2]; local g = screen[1].geometry; mouse.coords({ x = g.x + g.width / 2, y = g.y + g.height / 2 }); return tostring(client.get()[1].screen.index) .. "/" .. tostring(mouse.screen.index)' \
    "2/1"

sw_reload hr-screen || finish

check_eval hr-screen "the client is still on screen 2 after the reload" \
    'return tostring(client.get()[1].screen.index)' 2

sw_check_log_clean hr-screen "post-reload log"

finish
