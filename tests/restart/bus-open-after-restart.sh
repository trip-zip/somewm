#!/usr/bin/env bash
#
# The shared GDBus session connection must still be open after a hot-reload.
#
# This pins the mechanism behind the dead-notifications symptom. The reload used to close the
# process-wide session singleton during teardown; GLib caches it in a GWeakRef
# that is only cleared on finalize, so every later Gio.bus_get_sync returned the
# same closed object. notify-after-restart shows what that does to users; this
# shows the connection itself.
#
# The assertion has to run inside the compositor: connection state is private to
# the process, and no external tool can read it. naughty is not needed, because
# the teardown calls bus_get_sync itself and so materialises the singleton
# whatever the config does.
#
# The unique name rides along in the same probe, reported and not asserted.
# With the old state closed, the singleton finalises and the name changes; an
# abandoned state would keep it alive and the name stable. Asserting either
# way would couple this test to that implementation choice for no gain.

. "$(dirname "$0")/lib.sh"

STATE='local Gio = require("lgi").Gio; local b = Gio.bus_get_sync(Gio.BusType.SESSION); return tostring(b:is_closed()) .. " " .. tostring(b.unique_name)'

skip_unless_bus

check_bus_state() {
    local desc="$1"
    if sw_eval hr-bus "$STATE"; then
        check_match "$desc" "$EVAL_VALUE" '^false '
        info "unique name: ${EVAL_VALUE#* }"
    else
        fail "$desc" "$EVAL_ERROR"
    fi
}

sw_start hr-bus --config "$ROOT_DIR/tests/rc.lua" || finish

check_bus_state "the session bus is open before the reload"

sw_reload hr-bus || finish
check_bus_state "the session bus is still open after one reload"

sw_reload hr-bus || finish
check_bus_state "the session bus is still open after two reloads"

sw_check_log_clean hr-bus

finish
