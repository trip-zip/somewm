#!/usr/bin/env bash
#
# Animation handles must keep their metatable across a hot-reload.
#
# animation_setup() creates ANIM_HANDLE_MT and is called once, from somewm.c at
# boot. luaA_create_fresh_state never calls it, so after a reload
# luaA_start_animation does luaL_getmetatable (nil) followed by lua_setmetatable
# and every handle comes back with no methods. Calling handle:cancel() then
# errors.

. "$(dirname "$0")/lib.sh"

HANDLE='local h = awesome.start_animation(0.5, "linear", function() end); return tostring(getmetatable(h) ~= nil)'
CANCEL='local h = awesome.start_animation(0.5, "linear", function() end); return tostring(pcall(function() h:cancel() end))'

sw_start hr-anim --config "$ROOT_DIR/tests/rc.lua" || finish

check_eval hr-anim "handles have a metatable before the reload" "$HANDLE" true
check_eval hr-anim "handle:cancel() works before the reload" "$CANCEL" true

sw_reload hr-anim || finish

check_eval hr-anim "handles still have a metatable after the reload" "$HANDLE" true
check_eval hr-anim "handle:cancel() still works after the reload" "$CANCEL" true

sw_check_log_clean hr-anim

finish
