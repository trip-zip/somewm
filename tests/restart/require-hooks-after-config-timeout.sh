#!/usr/bin/env bash
#
# The require() hooks must reach a config retried after a timeout.
#
# They patch gears.surface, gears.wallpaper and awful.client.shape for Wayland:
# without them the wallpaper cache never gets a hit and every client shape
# update calls into an X11 extension that is not there. They used to be
# installed once at the top of luaA_loadrc(), above its config loop, while the
# timeout rebuilds the state inside that loop, so the retried config ran with
# none of them. Installing them from luaA_register_state() gives every state its
# own copy.
#
# The probe is the wallpaper hook's side table, which the patched require()
# creates when gears.wallpaper is first loaded and nothing else ever writes.

. "$(dirname "$0")/lib.sh"

sw_start_hung_config hr-req || finish

check_eval hr-req "the wallpaper require hook is installed after a timeout" \
    'require("gears.wallpaper"); return tostring(_somewm_wallpaper_screen_info ~= nil)' \
    true

check_eval hr-req "the shape updates are no-ops after a timeout" \
    'local s = require("awful.client.shape"); return tostring(s.update.all() == nil)' \
    true

sw_check_log_clean hr-req

finish
