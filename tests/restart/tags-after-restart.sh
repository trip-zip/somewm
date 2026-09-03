#!/usr/bin/env bash
#
# Client tag membership, selected tags, a tag's own state and floating geometry
# must survive a hot-reload.
#
# rc.lua builds every tag from scratch when it re-runs, so before the reload
# the compositor snapshots which tags each client was on and which were
# viewed, then re-applies both onto the tags the new config created, matched
# by name per screen. The earlier version of this test ran against
# tests/rc.lua, whose single tag made every wrong answer look right.
#
# Three reloads, one instance: the same config with two tags viewed, a shorter
# tag and layout list, and renamed tags.

. "$(dirname "$0")/lib.sh"

sw_require_helper test-fullscreen-client
CLIENT=$SW_HELPER

# Our own copy, because the reload re-reads the same -c path and the test
# rewrites the tag list between reloads.
CONFIG="$SOMEWM_RESTART_RUNTIME/tags-rc.lua"

set_tags() {
    sed -E "s/^( *awful\.tag\()\{[^}]*\}/\1{ $1 }/" \
        "$RESTART_DIR/configs/tags/rc.lua" > "$CONFIG"
    if ! grep -qF "awful.tag({ $1 }" "$CONFIG"; then
        fail "config rewritten to tags $1" "substitution did not apply"
        return 1
    fi
}

set_floating_only() {
    sed -i '/awful\.layout\.suit\.tile,/d' "$CONFIG"
    if grep -qF "awful.layout.suit.tile," "$CONFIG"; then
        fail "config limited to floating layout" "tile entry remains"
        return 1
    fi
}

# Tag names, selection, order and layout on the primary screen.
TAGS='local t = {}; for _, tg in ipairs(screen.primary.tags) do t[#t+1] = tg.name .. ":" .. tostring(tg.selected) .. ":" .. tg.layout.name end; return table.concat(t, ",")'

# Run a body against the client with this pid, as `c`.
for_client() {
    echo "local pid = $1; for _, c in ipairs(client.get()) do if c.pid == pid then $2 end end; return \"no client\""
}

# The sorted tag names of the client with this pid.
client_tags() {
    for_client "$1" 'local n = {}; for _, t in ipairs(c:tags()) do n[#n+1] = t.name end; table.sort(n); return table.concat(n, ",")'
}

# Exact outer geometry, floating state and rebuilt titlebar size for a client.
client_geometry() {
    for_client "$1" 'local g = c:geometry(); local _, top = c:titlebar_top(); return g.x .. "," .. g.y .. "," .. g.width .. "," .. g.height .. ":" .. tostring(c.floating) .. ":" .. top'
}

# The master and gap numbers awful keeps beside the layout, which live in Lua
# and so go with the state the reload closes.
NUMBERS='local t = screen.primary.tags[2]; return t.master_width_factor .. ":" .. t.master_count .. ":" .. t.column_count .. ":" .. t.gap'

# Move the client with this pid onto the tags at these 1-based positions.
retag() {
    for_client "$1" "local ts = screen.primary.tags; local sel = {}; for _, i in ipairs({$2}) do sel[#sel+1] = ts[i] end; c:tags(sel); return \"ok\""
}

# Both clients still have the geometry they started with.
check_geometry_stable() {
    check_eval hr-tags "client A geometry does not grow on the $1 reload" \
        "$(client_geometry "$PID_A")" "$before_geometry_a"
    check_eval hr-tags "client B geometry does not grow on the $1 reload" \
        "$(client_geometry "$PID_B")" "$before_geometry_b"
}

# View the tags at these 1-based positions, and only those.
view() {
    echo "local ts = screen.primary.tags; local sel = {}; for _, i in ipairs({$1}) do sel[#sel+1] = ts[i] end; require(\"awful\").tag.viewmore(sel, screen.primary); return \"ok\""
}

set_tags '"1", "2", "3"' || finish
sw_start hr-tags --config "$CONFIG" || finish

check_eval hr-tags "the config gave the screen three floating tags" "$TAGS" \
    "1:true:floating,2:false:floating,3:false:floating"

sw_spawn hr-tags "$CLIENT" || finish
check_client_appeared hr-tags fullscreen_test || finish
PID_A=$SPAWN_PID

sw_spawn hr-tags "$CLIENT" || finish
check_wait_true hr-tags "the second client appeared" \
    'return tostring(#client.get() == 2)' || finish
PID_B=$SPAWN_PID

check_eval hr-tags "client A moved to tag 3" "$(retag "$PID_A" 3)" ok
check_eval hr-tags "client B moved to tags 2 and 3" "$(retag "$PID_B" "2, 3")" ok
check_eval hr-tags "tag 2 changed to tile" \
    'screen.primary.tags[2].layout = require("awful").layout.suit.tile; return screen.primary.tags[2].layout.name' tile

sw_eval hr-tags "$NUMBERS"
default_numbers=$EVAL_VALUE
info "tag 2 numbers as the config left them: $default_numbers"
check_eval hr-tags "tag 2 given its own master and gap numbers" \
    'local t = screen.primary.tags[2]; t.master_width_factor = 0.7; t.master_count = 2; t.column_count = 3; t.gap = 5; return "ok"' \
    ok
check_eval hr-tags "tags 2 and 3 viewed together" "$(view "2, 3")" ok

sw_eval hr-tags "$(client_geometry "$PID_A")"
before_geometry_a=$EVAL_VALUE
sw_eval hr-tags "$(client_geometry "$PID_B")"
before_geometry_b=$EVAL_VALUE
check_match "client A starts floating with a 23px titlebar" \
    "$before_geometry_a" '^-?[0-9]+,-?[0-9]+,[1-9][0-9]*,[1-9][0-9]*:true:23$'
check_match "client B starts floating with a 23px titlebar" \
    "$before_geometry_b" '^-?[0-9]+,-?[0-9]+,[1-9][0-9]*,[1-9][0-9]*:true:23$'

# --- reload 1: the same config ----------------------------------------------

sw_reload hr-tags || finish

check_eval hr-tags "tag names, order and both viewed tags survive the reload" \
    "$TAGS" "1:false:floating,2:true:tile,3:true:floating"
check_eval hr-tags "client A is still on tag 3 alone" "$(client_tags "$PID_A")" "3"
check_eval hr-tags "client B is still on tags 2 and 3" "$(client_tags "$PID_B")" "2,3"
check_geometry_stable first
check_eval hr-tags "tag 2 keeps its master and gap numbers" "$NUMBERS" "0.7:2:3:5"

sw_check_log_clean hr-tags "log after the first reload" || finish

# --- reload 2: the third tag and tile layout are gone ------------------------

check_eval hr-tags "only tag 2 viewed" "$(view 2)" ok
set_tags '"1", "2"' || finish
set_floating_only || finish
sw_reload hr-tags || finish

check_eval hr-tags "an unavailable old layout falls back to rc.lua's default" \
    "$TAGS" "1:false:floating,2:true:floating"
check_eval hr-tags "client A resolves nothing and the rules place it on the restored selection" \
    "$(client_tags "$PID_A")" "2"
check_eval hr-tags "client B keeps the tag that still exists" "$(client_tags "$PID_B")" "2"
check_geometry_stable second

sw_check_log_clean hr-tags "log after the second reload" || finish

# --- reload 3: the tags are renamed -----------------------------------------

set_tags '"a", "b"' || finish
sw_reload hr-tags || finish

check_eval hr-tags "renamed tags keep rc.lua's selection and default layouts" \
    "$TAGS" "a:true:floating,b:false:floating"
check_eval hr-tags "client A falls through to the rules" "$(client_tags "$PID_A")" "a"
check_eval hr-tags "client B falls through to the rules" "$(client_tags "$PID_B")" "a"
check_geometry_stable third
check_eval hr-tags "the renamed tag matches nothing and keeps the config's numbers" \
    "$NUMBERS" "$default_numbers"

sw_check_log_clean hr-tags "log after the third reload"

finish
