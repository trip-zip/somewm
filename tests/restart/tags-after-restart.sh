#!/usr/bin/env bash
#
# Tags, and the clients attached to them, must survive a hot-reload.
#
# Replaces tests/test-hot-reload-tags.lua, which printed the tag list, called
# awesome.restart() and passed if nothing crashed. The client-to-tag association
# half is new: the reload snapshots tags by value and re-attaches clients to
# them, and nothing has ever checked that the association comes back.

. "$(dirname "$0")/lib.sh"

sw_require_helper test-fullscreen-client
CLIENT=$SW_HELPER

sw_start hr-tags --config "$ROOT_DIR/tests/rc.lua" || finish

TAGS='local t = {}; for _, tg in ipairs(screen.primary.tags) do t[#t+1] = tg.name .. ":" .. tostring(tg.selected) .. ":" .. tostring(tg.index) end; return table.concat(t, ",")'

sw_eval hr-tags "$TAGS"
before=$EVAL_VALUE
info "phase-1 tags: $before"
check_match "phase-1 has at least one tag" "$before" '^[^,]+:(true|false):[0-9]+'

sw_spawn hr-tags "$CLIENT" || finish
check_client_appeared hr-tags fullscreen_test || finish

CTAG='local c = client.get()[1]; if not c then return "no client" end; local ts = c:tags(); return tostring(#ts) .. ":" .. tostring(ts[1] and ts[1].name)'
sw_eval hr-tags "$CTAG"
before_ctag=$EVAL_VALUE
info "phase-1 client tags: $before_ctag"
check_match "phase-1 client is on a tag" "$before_ctag" '^[1-9][0-9]*:'

sw_reload hr-tags || finish

check_eval hr-tags "tag names, selection and order survive the reload" "$TAGS" "$before"
check_eval hr-tags "the screen still has a selected tag" \
    'return tostring(screen.primary.selected_tag ~= nil)' true
check_eval hr-tags "the client is still attached to the same tag" "$CTAG" "$before_ctag"

sw_check_log_clean hr-tags "post-reload log"

finish
