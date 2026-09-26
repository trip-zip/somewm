#!/usr/bin/env bash
# X11 position hints preserve an offscreen position when restart re-manages clients.

. "$(dirname "$0")/lib.sh"

sw_require_helper test-x11-grab-client
CLIENT=$SW_HELPER

config="$XDG_RUNTIME_DIR/position-hints.lua"
cat > "$config" <<'LUA'
package.path = os.getenv("SOMEWM_TEST_BASE_RC"):match("^(.*)/") .. "/?.lua;" .. package.path
dofile(os.getenv("SOMEWM_TEST_BASE_RC"))
local awful = require("awful")
local ruled = require("ruled")
-- Only the hinted client gets rule placement, so the unhinted client's
-- position observes awful.client's startup no_offscreen handler alone.
ruled.client.append_rule {
    rule = { class = "RestartHinted" },
    properties = {
        placement = function(c, args)
            -- Preserve the initial mapping position; place only on re-manage.
            if awesome.startup then
                awful.placement.no_offscreen(c, args)
            end
        end,
    },
}
LUA

sw_start hr-hints --config "$config" || finish
check_eval hr-hints "xterm is detected for the unhinted client" \
    'local app = require("_x11_client").get_app_info(); return app and app.executable or "unavailable"' xterm
[ "$fail_count" -eq 0 ] || finish

# XWayland starts lazily and its first client may never map.
sw_spawn hr-hints "$CLIENT $XDG_RUNTIME_DIR/warmup.marker RestartWarmup 100 100 100 100 no-grab" || finish
sw_wait_client hr-hints RestartWarmup 2 || info "warmup client did not map; continuing with the hinted client"

sw_spawn hr-hints "$CLIENT $XDG_RUNTIME_DIR/hinted.marker RestartHinted -200 100 300 200 no-grab" || finish
hinted_pid=$SPAWN_PID
check_client_appeared hr-hints RestartHinted || finish

HINTED='local c; for _, candidate in ipairs(client.get()) do if candidate.class == "RestartHinted" then c = candidate; break end end; assert(c, "hinted client missing"); '
UNHINTED='local c; for _, candidate in ipairs(client.get()) do if candidate.class == "RestartUnhinted" then c = candidate; break end end; assert(c, "unhinted client missing"); '
IDENTITY='return c.class .. ":" .. tostring(c.pid) .. ":" .. tostring(c.floating)'

check_eval hr-hints "hinted client is floating with its original class and pid" \
    "${HINTED}c.floating = true; $IDENTITY" "RestartHinted:$hinted_pid:true"
check_eval hr-hints "hinted client carries PPosition and PSize" \
    "${HINTED}return tostring(c.size_hints.program_position ~= nil and c.size_hints.program_size ~= nil)" true
check_eval hr-hints "hinted client starts at x=-200 without a geometry write" \
    "${HINTED}return c:geometry().x" -200
[ "$fail_count" -eq 0 ] || finish

sw_eval hr-hints 'return require("_x11_client")("RestartUnhinted")' || { fail "spawned unhinted xterm" "$EVAL_ERROR"; finish; }
unhinted_pid=$EVAL_VALUE
check_match "unhinted xterm spawn returned a pid" "$unhinted_pid" '^[1-9][0-9]*$'
check_client_appeared hr-hints RestartUnhinted || finish
check_eval hr-hints "unhinted client has no position hints" \
    "${UNHINTED}return tostring(not c.size_hints.user_position and not c.size_hints.program_position)" true
check_eval hr-hints "unhinted client is floating with its original class and pid" \
    "${UNHINTED}c.floating = true; c:geometry({x = -200}); $IDENTITY" "RestartUnhinted:$unhinted_pid:true"
check_eval hr-hints "unhinted client starts at x=-200" \
    "${UNHINTED}return c:geometry().x" -200
[ "$fail_count" -eq 0 ] || finish

sw_reload hr-hints || finish

POST_RELOAD='local tag = c.first_tag; local h = c.size_hints; return "class=" .. c.class .. " x=" .. c:geometry().x .. " floating=" .. tostring(c.floating) .. " tag_layout=" .. tostring(tag and tag.layout and tag.layout.name) .. " user_position=" .. tostring(h.user_position) .. " program_position=" .. tostring(h.program_position) .. " | " .. require("gears.debug").dump_return(h, "size_hints"):gsub("\n", " | ")'
for find_client in "$HINTED" "$UNHINTED"; do
    if sw_eval hr-hints "$find_client$POST_RELOAD"; then
        info "post-reload: $EVAL_VALUE"
    else
        fail "post-reload client diagnostics" "$EVAL_ERROR"
    fi
done
check_eval hr-hints "hinted client retains its program position hint after restart" \
    "${HINTED}return tostring(c.size_hints.program_position ~= nil)" true
check_eval hr-hints "unhinted client still has no position hints after restart" \
    "${UNHINTED}return tostring(not c.size_hints.user_position and not c.size_hints.program_position)" true
check_eval hr-hints "hinted client keeps x=-200 after restart" \
    "${HINTED}return c:geometry().x" -200
if sw_eval hr-hints "${UNHINTED}return c:geometry().x"; then
    check_match "unhinted client has x >= 0 after restart" "$EVAL_VALUE" '^[0-9]+([.]0+)?$'
else
    fail "unhinted client has x >= 0 after restart" "$EVAL_ERROR"
fi
IDENTITY='return c.class .. ":" .. tostring(c.pid)'
check_eval hr-hints "hinted class and pid survive restart" \
    "$HINTED$IDENTITY" "RestartHinted:$hinted_pid"
check_eval hr-hints "unhinted class and pid survive restart" \
    "$UNHINTED$IDENTITY" "RestartUnhinted:$unhinted_pid"
sw_check_log_clean hr-hints "post-reload log"

finish
