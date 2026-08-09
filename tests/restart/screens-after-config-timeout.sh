#!/usr/bin/env bash
#
# A config timeout must leave the screens intact.
#
# The timeout path closes the Lua state, which frees every screen and output
# userdata. The Monitor structs and the C-side ref arrays survive, so without a
# rebuild the fresh state holds registry ints into a closed state: screen.primary
# reads nil, pushing a stale ref warns "Trying to emit signal ... on non-object",
# and naughty's startup-error fallback concludes no screen exists and the
# startup error notification is silently lost.
#
# The counts assume the harness default of a single headless output.

. "$(dirname "$0")/lib.sh"

sw_start_hung_config hr-scr || finish

check_eval hr-scr "one screen per output, and it is a real one" \
    'return "count=" .. screen.count() .. "|outputs=" .. #screen._viewports()' \
    'count=1|outputs=1'

check_eval hr-scr "the screen came from C" \
    'return tostring(screen[1]._managed)' C

check_eval hr-scr "there is a primary screen" \
    'return tostring(screen.primary ~= nil)' true

check_eval hr-scr "the focused screen is the real one" \
    'return tostring(require("awful.screen").focused() == screen[1])' true

if log_has hr-scr "non-object"; then
    fail "no signal was emitted on a stale screen ref" \
         "$(grep -F -- "non-object" "$(sw_log hr-scr)" | head -3)"
else
    pass "no signal was emitted on a stale screen ref"
fi

sw_check_log_clean hr-scr "post-timeout log"

finish
