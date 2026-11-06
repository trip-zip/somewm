#!/usr/bin/env bash

. "$(dirname "$0")/lib.sh"

sw_start ui-box --config "$ROOT_DIR/tests/rc.lua" || finish
sw_eval ui-box 'return #screen[1].tree.children'
before=$EVAL_VALUE
check_eval ui-box 'a box adds one screen child' \
    'local s = screen[1]; local before = #s.tree.children; require("ui").box {parent=s, width=80, height=30, bg="#00ff00"}; return #s.tree.children == before + 1' true
sw_reload ui-box || finish
check_eval ui-box 'reload removes the old box' 'return #screen[1].tree.children' "$before"
check_eval ui-box 'the reloaded dump has no box' \
    'return awesome._clay_tree(screen[1]):find("ui.box", 1, true) == nil' true
sw_check_log_clean ui-box
finish
