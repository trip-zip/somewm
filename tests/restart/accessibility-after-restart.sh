#!/usr/bin/env bash
# Active pointer locators release their timers and native magnification on reload.
. "$(dirname "$0")/lib.sh"

sw_start hr-a11y --config "$ROOT_DIR/tests/rc.lua" || finish
check_eval hr-a11y "magnification starts" \
    'A11Y = require("awful.accessibility") {cursor_finder_effect="both", cursor_finder_shake_enabled=true, cursor_finder_inflate_duration=0, cursor_finder_deflate_delay=30}; A11Y:find_cursor(); return root._cursor_magnify()' 3
sw_reload hr-a11y || finish
check_eval hr-a11y "reload restores normal cursor" 'return root._cursor_magnify()' 1
check_eval hr-a11y "new state can activate locator" \
    'A11Y = require("awful.accessibility") {cursor_finder_effect="magnify", cursor_finder_inflate_duration=0, cursor_finder_deflate_delay=30}; A11Y:find_cursor(); return root._cursor_magnify()' 3
sw_reload hr-a11y || finish
check_eval hr-a11y "second reload restores normal cursor" 'return root._cursor_magnify()' 1
sw_check_log_clean hr-a11y
finish
