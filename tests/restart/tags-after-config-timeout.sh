#!/usr/bin/env bash
#
# A config that builds tags and a drawin before hanging must not leave the
# recovery holding freed pointers.
#
# The abort closes the Lua state, which frees every tag and drawin userdata.
# globalconf.tags and globalconf.drawins are C-side arrays that survive, so
# unless the recovery drops them the retried config runs with freed pointers
# in both: root.tags() pushes them, and every EWMH update walks
# tags.tab[i]->selected.

. "$(dirname "$0")/lib.sh"

sw_start_hung_config hr-ui "$ROOT_DIR/tests/rc.lua" hang-after-ui || finish

# The fallback config creates exactly one tag and no drawins. Anything more
# in the C arrays is a survivor from the aborted config.
check_eval hr-ui "root.tags() holds only the fallback's tag" \
    'local ts = root.tags(); return "n=" .. #ts .. "|name=" .. tostring(ts[1] and ts[1].name)' \
    'n=1|name=test'

check_eval hr-ui "root.drawins() is empty" \
    'return "n=" .. #root.drawins()' 'n=0'

# Walks the tag array after tag state changed, the same walk the EWMH
# update does on every selection change.
check_eval hr-ui "tag selection still works after recovery" \
    'local t = root.tags()[1]; t.selected = false; t.selected = true; return tostring(t.selected)' \
    true

sw_check_log_clean hr-ui "post-timeout log"

finish
