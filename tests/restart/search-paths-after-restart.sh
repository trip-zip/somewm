#!/usr/bin/env bash
#
# A rebuilt Lua state must get the same search paths as a booted one.
#
# luaA_init and luaA_create_fresh_state used to carry two hand-maintained
# copies of the registration list. They had already drifted: only the boot copy
# prepended somewm's own package.cpath, so after a reload require() resolved C
# modules off LuaJIT's default cpath alone. package.path was set on both paths,
# which is why nothing noticed.
#
# Both now run luaA_register_state, so this pins the halves against each other.

. "$(dirname "$0")/lib.sh"

# find() with plain=true: these contain '?' and '.', which are pattern chars.
CPATH='return tostring(string.find(package.cpath, "./lua/?.so", 1, true) ~= nil)'
PATH_='return tostring(string.find(package.path, "./lua/?.lua", 1, true) ~= nil)'

sw_start hr-paths --config "$ROOT_DIR/tests/rc.lua" || finish

check_eval hr-paths "package.path has somewm's entries before the reload" "$PATH_" true
check_eval hr-paths "package.cpath has somewm's entries before the reload" "$CPATH" true

sw_reload hr-paths || finish

check_eval hr-paths "package.path survives the reload" "$PATH_" true
check_eval hr-paths "package.cpath survives the reload" "$CPATH" true

sw_check_log_clean hr-paths "post-reload log"

finish
