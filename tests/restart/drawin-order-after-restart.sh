#!/usr/bin/env bash

. "$(dirname "$0")/lib.sh"

export SOMEWM_ORDER_ROOT="$ROOT_DIR"
box=$(sw_sandbox)
cat > "$box/rc.lua" <<'LUA'
package.path = os.getenv('SOMEWM_ORDER_ROOT') .. '/tests/?.lua;' .. package.path
dofile(os.getenv('SOMEWM_TEST_BASE_RC'))
local fixture = require('_state_tree_drawin_order')
require('awful').screen.connect_for_each_screen(function(s)
    s.order_pair = fixture.create(s)
    fixture.raise_first(s.order_pair)
end)
mouse.coords {x = 900, y = 600}
LUA

sw_start hr-drawin-order --config "$box/rc.lua" || finish
MATCH='return tostring(require("_state_tree_drawin_order").matches(screen.primary.order_pair, true))'
sw_wait_true hr-drawin-order "$MATCH" 10 || finish

dump_dir="$ARTIFACT_DIR/$TEST_NAME"
mkdir -p "$dump_dir"
capture() {
    local phase="$1"
    sw_eval hr-drawin-order 'return awesome._clay_tree(screen.primary)' || return 1
    printf '%s\n' "$EVAL_VALUE" > "$dump_dir/$phase.dump"
    sw_eval hr-drawin-order 'local d = awesome._clay_tree(screen.primary); local s = require("_clay_golden").shape(d); for line in d:match("  realized:\n(.*)"):gmatch("[^\n]+") do if not line:find(" cursor ", 1, true) then s = s .. line:gsub("%f[%x]%x%x%x%x%x%x%x%x%f[^%x]", "ID") .. "\n" end end; return s:gsub("font=%d+", "font=N")' || return 1
    printf '%s\n' "$EVAL_VALUE" > "$dump_dir/$phase.normalized"
}

capture before || finish
sw_reload hr-drawin-order || finish
sw_wait_true hr-drawin-order "$MATCH" 10 || finish
capture after || finish
if diff -u "$dump_dir/before.normalized" "$dump_dir/after.normalized"; then
    pass "config-authored drawin order and pixels survive reload"
else
    fail "config-authored drawin order and pixels survive reload"
fi
sw_check_log_clean hr-drawin-order "post-reload log"
finish
