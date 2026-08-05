#!/usr/bin/env bash
#
# Census of the bus names the compositor owns, before and after a hot-reload.
#
# The original wording for this test was "after the exit signal, no
# somewm-owned names remain". That moment is not observable: exit is emitted and
# the fresh state is built inside one synchronous GLib dispatch, so no external
# observer can sample the bus in between. A post-reload ownership census keeps
# the diagnostic value and can actually run.
#
# It also prints the source-sweep count every run. That number falling to zero
# is the cleanest single signal that the exit teardown contract holds: the
# sweep exists to catch what modules failed to release on exit.

# xfail: naughty never re-owns its name after the reload and statusnotifierwatcher never releases anything

. "$(dirname "$0")/lib.sh"

skip_unless_bus

sw_start hr-census --config "$RESTART_DIR/configs/rc-dbus.lua" || finish

check_bus_owner hr-census org.awesomewm.awful \
    "phase-1: instance owns org.awesomewm.awful"
check_bus_owner hr-census org.freedesktop.Notifications \
    "phase-1: instance owns org.freedesktop.Notifications"

sw_reload hr-census || finish

# libdbus connections are process-lifetime by design (dbus.c:54-55), so this
# name is expected to survive; it is the control for the one below.
check_bus_owner hr-census org.awesomewm.awful \
    "phase-2: instance still owns org.awesomewm.awful"
check_bus_owner hr-census org.freedesktop.Notifications \
    "phase-2: instance still owns org.freedesktop.Notifications"

sw_report_sweep hr-census

finish
