#!/usr/bin/env bash
#
# A hot-reload must not leave selection listeners pointed at the destroyed state.
#
# selection.watcher embeds its two wl_listeners in the userdata and links
# them into the seat; selection.acquire embeds a destroy listener in the userdata
# and the seat keeps its data source alive. The reload dropped neither, so every
# later clipboard change dispatched into objects belonging to a state that was
# gone, and the acquire path also luaL_unref'd an old-state ref against the new
# state's tracking table.
#
# One clipboard change is one seat set_selection, so the dispatch lines in the log
# count watchers. Note that a dispatch to the *live* watcher also logs a non-object
# line: selection objects are never entered into the object registry, so
# luaA_object_push cannot find them and the signal never reaches Lua. That is a
# separate, pre-existing defect (issue 659); it is why the expected count here is 2
# rather than 0. A third line is the abandoned watcher.

. "$(dirname "$0")/lib.sh"

CHANGED="'selection_changed' on non-object"
RELEASED="'release' on non-object"

# The dispatch is synchronous: the acquire calls wlr_seat_set_selection inside the
# Lua chunk, wlroots emits set_selection from there, and warn() is an unbuffered
# write. The line is on disk before the eval replies, so there is nothing to wait
# for between the acquire and the count.
PROBE='ACQ = selection.acquire{selection = "CLIPBOARD", mime_types = {"text/plain"}}; return tostring(SEL_WATCHER.active) .. "|" .. tostring(ACQ.active)'

sw_start hr-sel --config "$RESTART_DIR/configs/rc-selection.lua" || finish

check_eval hr-sel "the watcher is active and the clipboard can be acquired" \
    "$PROBE" "true|true"
check_log_count hr-sel "one clipboard change dispatches to the one live watcher" \
    "$CHANGED" 1

sw_reload hr-sel || finish

check_eval hr-sel "the rebuilt state has its own watcher and can acquire again" \
    "$PROBE" "true|true"

check_log_count hr-sel "the reload left no second watcher on the seat" \
    "$CHANGED" 2
check_log_count hr-sel "the abandoned acquire never fires release" \
    "$RELEASED" 0

sw_check_log_clean hr-sel "post-reload log"

finish
