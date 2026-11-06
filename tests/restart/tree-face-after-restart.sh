#!/usr/bin/env bash
# Screen and client node ids survive replacement of their Lua faces.

. "$(dirname "$0")/lib.sh"

sw_require_helper test-fullscreen-client
CLIENT=$SW_HELPER
sw_start hr-tree-face --config "$ROOT_DIR/tests/rc.lua" || finish
sw_spawn hr-tree-face "$CLIENT" || finish
check_client_appeared hr-tree-face fullscreen_test || finish

IDS='local c = client.get()[1]; for _, n in ipairs(c.parent.children) do if n.object == c then return string.format("%d,%d", c.parent.id, n.id) end end'
sw_eval hr-tree-face "$IDS"
before=$EVAL_VALUE
check_match "screen and client ids recorded" "$before" '^[0-9]+,[0-9]+$'
check_eval hr-tree-face "screen face is the client parent" 'local c = client.get()[1]; return c.parent == c.screen.tree and type(c.parent) == "node"' true

sw_reload hr-tree-face || finish

check_eval hr-tree-face "node ids survive reload" "$IDS" "$before"
check_eval hr-tree-face "fresh faces resolve screen and client owners" 'local c = client.get()[1]; local root = c.screen.tree; assert(root == c.parent and root.object == c.screen and root.root == root and root.parent == nil); for _, n in ipairs(root.children) do if n.object == c then return n.parent == root and n == root.children[_] end end' true
sw_check_log_clean hr-tree-face "post-reload log"
finish
