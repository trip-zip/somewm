#!/usr/bin/env bash
#
# statusnotifierwatcher hands its D-Bus state back on "exit".
#
# Every Lua state owns org.kde.StatusNotifierWatcher on the one process-wide
# GDBus connection, so ownership cannot answer this: the name resolves to the
# same connection and the same pid whether or not the abandoned state released
# it. What a missing release does is kill the service. The rebuilt state asks
# for a name its own connection already owns, which GLib reports as name_lost,
# and exports an object path that is already exported, which fails with
# G_IO_ERROR_EXISTS. The path stays wired to the abandoned state, whose closures
# the lgi guard blocks, so a property read comes back "Unable to retrieve
# property" (observed, with the "exit" handler reverted).
#
# So the probe is functional, and it has to identify which state answered: seed
# a phase-unique marker into the live state's item list, then read the list back
# from outside. The reply must carry this phase's marker and not the previous
# phase's.
#
# Every phase also checks the owner still resolves to this instance, so a pass
# can never come from some other tray service on the bus.

. "$(dirname "$0")/lib.sh"

skip_unless_bus

SNW=org.kde.StatusNotifierWatcher
SNW_PATH=/StatusNotifierWatcher

check_watcher_serves() {
    local marker="$1" stale="${2-}"

    # One probe, polled: watcher.init runs off a GLib idle, so a fresh state has
    # not necessarily claimed anything yet, and seeding is idempotent. It waits
    # on the module having run, not on it having succeeded, because a state that
    # fails to claim still reports initialized.
    if ! sw_wait_true hr-snw \
        "local w = require('awful.statusnotifierwatcher'); w._private.registered_items['$marker'] = true; return tostring(w._private.initialized)" 5
    then
        fail "$marker: the live state took a seeded item" "${EVAL_ERROR:-$EVAL_VALUE}"
        return 1
    fi

    if ! sw_bus_call "$SNW" "$SNW_PATH" org.freedesktop.DBus.Properties.Get \
        "$SNW" RegisteredStatusNotifierItems; then
        fail "$marker: the watcher answers on $SNW_PATH" "$BUS_OUT"
        return 1
    fi
    check_match "$marker: the watcher answers with this state's items" \
        "$BUS_OUT" "'$marker'"

    [ -n "$stale" ] || return 0
    if echo "$BUS_OUT" | grep -qF "'$stale'"; then
        fail "$marker: the answer is not the abandoned state's" \
             "the reply still carries '$stale': $BUS_OUT"
    else
        pass "$marker: the answer is not the abandoned state's"
    fi
}

sw_start hr-snw --config "$ROOT_DIR/tests/rc.lua" || finish

# The service probe runs first in every phase: it waits out the fresh state's
# init idle, so the ownership check behind it is never a single early sample.
check_watcher_serves p1
check_bus_owner hr-snw "$SNW" "phase-1: this instance owns $SNW"

sw_reload hr-snw || finish
check_watcher_serves p2 p1
check_bus_owner hr-snw "$SNW" "phase-2: this instance still owns $SNW"

# Two reloads, because the second one runs against a state that was itself
# rebuilt. Anything D-Bus in this series has shown up on the second one before.
sw_reload hr-snw || finish
check_watcher_serves p3 p2
check_bus_owner hr-snw "$SNW" "phase-3: this instance still owns $SNW"

sw_check_log_clean hr-snw "post-reload log"

finish
