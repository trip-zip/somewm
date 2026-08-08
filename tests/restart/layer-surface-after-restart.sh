#!/usr/bin/env bash
#
# Layer surfaces must come back from a hot-reload as live Lua objects.
#
# The three wl_listeners belong to the C LayerSurface that createlayersurface()
# heap-allocates, and the reload never frees it, so the surface keeps rendering and
# the client never notices. What went stale was only the Lua half:
# globalconf.layer_surfaces and every LayerSurface.lua_object still pointed at
# userdata from the destroyed state, so layer_surface.get() came back empty while
# the panel was still on screen, and the next commit or unmap pushed a dead pointer
# into the new state.

. "$(dirname "$0")/lib.sh"

sw_require_helper test-layer-client
CLIENT=$SW_HELPER

sw_start hr-layer --config "$ROOT_DIR/tests/rc.lua" || finish

sw_spawn hr-layer "$CLIENT --namespace panel-one --keyboard none" || finish
check_wait_true hr-layer "the layer surface was managed" \
    'return tostring(#layer_surface.get() == 1)' || finish
FIRST_PID=$SPAWN_PID

sw_spawn hr-layer "$CLIENT --namespace panel-two --keyboard none" || finish
check_wait_true hr-layer "the second layer surface was managed" \
    'return tostring(#layer_surface.get() == 2)' || finish

IDENT='local t = {}; for _, ls in ipairs(layer_surface.get()) do t[#t+1] = ls.namespace .. ":" .. ls.layer .. ":" .. tostring(ls.mapped) .. ":" .. tostring(ls.screen and ls.screen.index) .. ":" .. tostring(ls.valid) end; return table.concat(t, "|")'

sw_eval hr-layer "$IDENT"
before=$EVAL_VALUE
info "phase-1: $before"
check_match "phase-1 is two real surfaces" "$before" \
    '^panel-two:[a-z]+:true:[0-9]+:true\|panel-one:'

sw_reload hr-layer || finish

check_eval hr-layer "namespace, layer, mapped, screen, validity and order survive the reload" \
    "$IDENT" "$before"

kill -0 "$FIRST_PID" 2>/dev/null \
    && pass "the layer client process survived the reload" \
    || fail "the layer client process survived the reload"

# Control: manage still works in the rebuilt state, so a passing test above
# cannot come from the old array simply being left in place.
sw_spawn hr-layer "$CLIENT --namespace panel-three --keyboard none" || finish
check_wait_true hr-layer "a surface that arrives after the reload is still managed" \
    'return tostring(#layer_surface.get() == 3)'

check_log_count hr-layer "no signal was emitted on a dead layer surface" \
    "Trying to emit signal" 0

sw_check_log_clean hr-layer "post-reload log"

finish
