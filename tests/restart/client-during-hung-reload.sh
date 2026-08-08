#!/usr/bin/env bash
#
# A reload whose new config hangs must not take the clients with it.
#
# luaA_hot_reload() calls luaA_loadrc(), and luaA_loadrc() aborts a hanging
# config by closing the Lua state and building another one. Reached from a
# reload, that close frees client userdata with live wl_listeners embedded, and
# leaves globalconf.clients pointing at it: a use-after-free, and the reload
# then runs its remaining phases against a closed state.
#
# Startup can't show this, because no client exists while the first config
# loads. Only a reload can, so the config has to be swapped underneath a
# running instance.

. "$(dirname "$0")/lib.sh"

sw_require_helper test-fullscreen-client
CLIENT=$SW_HELPER

box=$(sw_sandbox)
mkdir -p "$box/cwd" "$box/home" "$box/config/somewm"
cp "$ROOT_DIR/tests/rc.lua" "$box/config/somewm/rc.lua"
cp "$RESTART_DIR/configs/fallback/somewmrc.lua" "$box/cwd/somewmrc.lua"
ln -s "$ROOT_DIR/lua" "$box/cwd/lua"

sw_start_env hr-hung "$box/cwd" \
    HOME="$box/home" \
    XDG_CONFIG_HOME="$box/config" \
    SOMEWM_TEST_FALLBACK_RC="$ROOT_DIR/tests/rc.lua" \
    || finish

sw_spawn hr-hung "$CLIENT" || finish
check_client_appeared hr-hung fullscreen_test || finish

IDENT='local t = {}; for _, c in ipairs(client.get()) do t[#t+1] = c.class .. ":" .. tostring(c.pid) .. ":" .. tostring(c.valid) end; return table.concat(t, "|")'
sw_eval hr-hung "$IDENT"
before=$EVAL_VALUE
info "phase-1 identity: $before"
check_match "phase-1 identity is a real client" "$before" '^fullscreen_test:[0-9]+:true$'

# Swap the config the reload will load for one that never returns.
cp "$RESTART_DIR/configs/hang/somewm/rc.lua" "$box/config/somewm/rc.lua"

# 10s alarm plus the rest of the reload, so the default barrier is too short.
sw_reload hr-hung 40 || finish

check_log hr-hung "the reloaded config was aborted" "FORCEFULLY ABORTED after timeout"
check_eval hr-hung "the fallback config we control is what loaded" \
    'return tostring(SOMEWM_TEST_FALLBACK)' true
check_eval hr-hung "the client survived the abort" "$IDENT" "$before"
check_eval hr-hung "exactly one client afterwards" 'return tostring(#client.get())' 1
check_eval hr-hung "the client still has a screen" \
    'return tostring(client.get()[1].screen ~= nil)' true

# The abort closed the state the reload had just put the clients into, so the
# phases after luaA_loadrc() ran against whatever came back. Managing a new
# client afterwards is the cheapest proof they ran against a live one.
sw_spawn hr-hung "$CLIENT" || finish
check_wait_true hr-hung "a client spawned after the abort is managed" \
    'return tostring(#client.get() == 2)'

sw_check_log_clean hr-hung "post-abort log"

finish
