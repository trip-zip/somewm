#!/usr/bin/env bash
#
# Client tag membership and the selected tags must survive a hot-reload.
#
# rc.lua builds every tag from scratch when it re-runs, so before the reload
# the compositor snapshots which tags each client was on and which were
# viewed, then re-applies both onto the tags the new config created, matched
# by name per screen. The earlier version of this test ran against
# tests/rc.lua, whose single tag made every wrong answer look right.
#
# Three reloads, one instance: the same config with two tags viewed, a shorter
# tag list, and a renamed one.

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

# Tag names, selection and order on the primary screen.
TAGS='local t = {}; for _, tg in ipairs(screen.primary.tags) do t[#t+1] = tg.name .. ":" .. tostring(tg.selected) end; return table.concat(t, ",")'

# The sorted tag names of the client with this pid.
client_tags() {
    echo "local pid = $1; for _, c in ipairs(client.get()) do if c.pid == pid then local n = {}; for _, t in ipairs(c:tags()) do n[#n+1] = t.name end; table.sort(n); return table.concat(n, \",\") end end; return \"no client\""
}

# Move the client with this pid onto the tags at these 1-based positions.
retag() {
    local pid="$1" idx="$2"
    echo "local pid = $pid; for _, c in ipairs(client.get()) do if c.pid == pid then local ts = screen.primary.tags; local sel = {}; for _, i in ipairs({$idx}) do sel[#sel+1] = ts[i] end; c:tags(sel); return \"ok\" end end; return \"no client\""
}

# View the tags at these 1-based positions, and only those.
view() {
    echo "local ts = screen.primary.tags; local sel = {}; for _, i in ipairs({$1}) do sel[#sel+1] = ts[i] end; require(\"awful\").tag.viewmore(sel, screen.primary); return \"ok\""
}

set_tags '"1", "2", "3"' || finish
sw_start hr-tags --config "$CONFIG" || finish

check_eval hr-tags "the config gave the screen three tags" "$TAGS" "1:true,2:false,3:false"

sw_spawn hr-tags "$CLIENT" || finish
check_client_appeared hr-tags fullscreen_test || finish
PID_A=$SPAWN_PID

sw_spawn hr-tags "$CLIENT" || finish
check_wait_true hr-tags "the second client appeared" \
    'return tostring(#client.get() == 2)' || finish
PID_B=$SPAWN_PID

check_eval hr-tags "client A moved to tag 3" "$(retag "$PID_A" 3)" ok
check_eval hr-tags "client B moved to tags 2 and 3" "$(retag "$PID_B" "2, 3")" ok
check_eval hr-tags "tags 2 and 3 viewed together" "$(view "2, 3")" ok

# --- reload 1: the same config ----------------------------------------------

sw_reload hr-tags || finish

check_eval hr-tags "tag names, order and both viewed tags survive the reload" \
    "$TAGS" "1:false,2:true,3:true"
check_eval hr-tags "client A is still on tag 3 alone" "$(client_tags "$PID_A")" "3"
check_eval hr-tags "client B is still on tags 2 and 3" "$(client_tags "$PID_B")" "2,3"

sw_check_log_clean hr-tags "log after the first reload" || finish

# --- reload 2: the third tag is gone -----------------------------------------

check_eval hr-tags "only tag 2 viewed" "$(view 2)" ok
set_tags '"1", "2"' || finish
sw_reload hr-tags || finish

check_eval hr-tags "the shorter tag list loads with tag 2 still viewed" "$TAGS" "1:false,2:true"
check_eval hr-tags "client A resolves nothing and the rules place it on the restored selection" \
    "$(client_tags "$PID_A")" "2"
check_eval hr-tags "client B keeps the tag that still exists" "$(client_tags "$PID_B")" "2"

sw_check_log_clean hr-tags "log after the second reload" || finish

# --- reload 3: the tags are renamed -----------------------------------------

set_tags '"a", "b"' || finish
sw_reload hr-tags || finish

check_eval hr-tags "the renamed tags load with rc.lua's own selection" "$TAGS" "a:true,b:false"
check_eval hr-tags "client A falls through to the rules" "$(client_tags "$PID_A")" "a"
check_eval hr-tags "client B falls through to the rules" "$(client_tags "$PID_B")" "a"

sw_check_log_clean hr-tags "log after the third reload"

finish
