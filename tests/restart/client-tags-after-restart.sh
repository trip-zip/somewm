#!/usr/bin/env bash

. "$(dirname "$0")/lib.sh"

sw_require_helper test-fullscreen-client
CLIENT=$SW_HELPER
box=$(sw_sandbox)
cat > "$box/rc.lua" <<'LUA'
dofile(os.getenv("SOMEWM_TEST_BASE_RC"))
local awful = require("awful")
awful.screen.connect_for_each_screen(function(s)
    s.tags[1].name = "1"
    awful.tag.add("2", {screen = s, layout = awful.layout.suit.floating})
    awful.tag.add("3", {screen = s, layout = awful.layout.suit.floating})
    for _ = 1, 3 do
        awful.tag.add("duplicate", {screen = s, layout = awful.layout.suit.floating})
    end
end)
LUA

sw_start hr-client-tags --config "$box/rc.lua" || finish
sw_spawn hr-client-tags "$CLIENT" || finish
pid_a=$SPAWN_PID
check_client_appeared hr-client-tags fullscreen_test || finish

check_eval hr-client-tags "move the first client to tag 3" \
    'local c = client.get()[1]; c:tags({c.screen.tags[3]}); return true' true
PROBE_A="local c; for _, v in ipairs(client.get()) do if v.pid == $pid_a then c = v end end; if not c then return 'missing' end; local names = {}; for _, t in ipairs(c:tags()) do names[#names+1] = t.name end; return table.concat(names, ',') .. '|visible=' .. tostring(c:isvisible())"
sw_eval hr-client-tags "$PROBE_A"
before_a=$EVAL_VALUE
check "first client is hidden on tag 3" "$before_a" '3|visible=false'
check_eval hr-client-tags "tag 1 stays selected" 'return screen.primary.selected_tag.name' 1

sw_reload hr-client-tags || finish
check_eval hr-client-tags "tag names and hidden visibility survive" "$PROBE_A" "$before_a"
check_eval hr-client-tags "tag 1 is still selected after reload" 'return screen.primary.selected_tag.name' 1

sw_spawn hr-client-tags "$CLIENT" || finish
pid_b=$SPAWN_PID
sw_wait_true hr-client-tags 'return tostring(#client.get() == 2)' 10
check_eval hr-client-tags "put the second client on tags 2 and 3 with sticky set" \
    "for _, c in ipairs(client.get()) do if c.pid == $pid_b then c:tags({c.screen.tags[2], c.screen.tags[3]}); c.sticky = true; return true end end" true
PROBE_B="local c; for _, v in ipairs(client.get()) do if v.pid == $pid_b then c = v end end; if not c then return 'missing' end; local names = {}; for _, t in ipairs(c:tags()) do names[#names+1] = t.name end; return table.concat(names, ',') .. '|sticky=' .. tostring(c.sticky)"
sw_eval hr-client-tags "$PROBE_B"
before_b=$EVAL_VALUE
check "second client has both tags and sticky" "$before_b" '2,3|sticky=true'

sw_reload hr-client-tags || finish
check_eval hr-client-tags "both tag names and sticky survive" "$PROBE_B" "$before_b"
check_eval hr-client-tags "the first client stays hidden after another reload" "$PROBE_A" "$before_a"

check_eval hr-client-tags "assign duplicate names and a temporary tag" \
    "for _, c in ipairs(client.get()) do if c.pid == $pid_a then local s = c.screen; local t = require('awful').tag.add('temporary', {screen = s}); c:tags({s.tags[5], s.tags[6], t}); return true end end" true
sw_reload hr-client-tags || finish
check_eval hr-client-tags "duplicate names claim tags in index order and missing names are dropped" \
    "for _, c in ipairs(client.get()) do if c.pid == $pid_a then local ts = c:tags(); return tostring(#ts) .. ':' .. tostring(ts[1] and ts[1].index) .. ',' .. tostring(ts[2] and ts[2].index) end end" '2:4,5'

check_eval hr-client-tags "assign only a temporary tag" \
    "for _, c in ipairs(client.get()) do if c.pid == $pid_a then c:tags({require('awful').tag.add('temporary', {screen = c.screen})}); return true end end" true
sw_reload hr-client-tags || finish
check_eval hr-client-tags "selected-tag fallback applies when no saved name matches" "$PROBE_A" '1|visible=true'
sw_check_log_clean hr-client-tags "post-reload log"
finish
