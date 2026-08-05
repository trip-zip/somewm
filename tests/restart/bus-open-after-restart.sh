#!/usr/bin/env bash
#
# The shared GDBus session connection must still be open after a hot-reload.
#
# This pins the mechanism behind the dead-notifications symptom. luaa.c:5222-5230 closes the
# process-wide session singleton during teardown; GLib caches it in a GWeakRef
# that is only cleared on finalize, so every later Gio.bus_get_sync returns the
# same closed object. notify-after-restart shows what that does to users; this
# shows the closed connection itself.
#
# The assertion has to run inside the compositor: connection state is private to
# the process, and no external tool can read it. naughty is not needed, because
# the teardown calls bus_get_sync itself and so materialises the singleton
# whatever the config does.

# xfail: the reload closes the session bus singleton and GLib's cache keeps handing back the closed object

. "$(dirname "$0")/lib.sh"

IS_CLOSED='local Gio = require("lgi").Gio; local b = Gio.bus_get_sync(Gio.BusType.SESSION); return tostring(b:is_closed())'
UNIQUE='local Gio = require("lgi").Gio; local b = Gio.bus_get_sync(Gio.BusType.SESSION); return tostring(b.unique_name)'

skip_unless_bus

sw_start hr-bus --config "$ROOT_DIR/tests/rc.lua" || finish

check_eval hr-bus "the session bus is open before the reload" "$IS_CLOSED" false
sw_eval hr-bus "$UNIQUE"
info "phase-1 unique name: $EVAL_VALUE"

sw_reload hr-bus || finish

check_eval hr-bus "the session bus is still open after the reload" "$IS_CLOSED" false

# Informational, not asserted: once the old state is torn down properly, the
# singleton finalises and the next bus_get_sync returns a brand-new connection,
# so this name should change. Asserting it now would couple the test to a
# teardown decision that has not been made.
sw_eval hr-bus "$UNIQUE"
info "phase-2 unique name: $EVAL_VALUE"

finish
