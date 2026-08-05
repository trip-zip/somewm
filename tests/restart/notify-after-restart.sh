#!/usr/bin/env bash
#
# Notifications must still work after a hot-reload. This is the regression test
# for issue 444.
#
# The reload used to close the shared GDBus session connection. GLib caches that
# connection in a GWeakRef cleared only on finalize, so every later
# Gio.bus_get_sync handed back the closed object, and naughty's bus_own_name
# rides that cache. Its owner id was discarded at creation, so the name could
# never be re-acquired either. naughty now releases the name on "exit" and the
# reload leaves the connection alone.
#
# Both halves matter. gdbus proves what an external client sees, which is what
# the defect is; an in-compositor Notify would ride the same poisoned singleton
# and fail for the wrong reason. NOTIF_COUNT proves the call reached this
# compositor rather than some other daemon on the bus.

. "$(dirname "$0")/lib.sh"

skip_unless_bus

NOTIFY_NAME=org.freedesktop.Notifications
NOTIFY_PATH=/org/freedesktop/Notifications

sw_start hr-notify --config "$RESTART_DIR/configs/rc-dbus.lua" || finish

inst_pid=$(sw_pid hr-notify)

# Without this, an activated dunst/mako on the private bus would answer every
# Notify and make this regression test permanently green.
owner_pid=$(sw_bus_owner_pid "$NOTIFY_NAME") || skip "$NOTIFY_NAME has no owner before the reload"
[ "$owner_pid" = "$inst_pid" ] || skip "$NOTIFY_NAME owned by pid $owner_pid, not the instance ($inst_pid)"
pass "the instance owns $NOTIFY_NAME before the reload"

notify() {
    sw_bus_call "$NOTIFY_NAME" "$NOTIFY_PATH" "$NOTIFY_NAME.Notify" \
        somewm-test 0 "" "$1" body "[]" "{}" 2000
}

notify phase1
check_match "phase-1 Notify returns an id" "$BUS_OUT" '^\(uint32 [0-9]+,\)$'
check_eval hr-notify "phase-1 notification reached this compositor" \
    'return tostring(NOTIF_COUNT)' 1

sw_reload hr-notify || finish

check_bus_owner hr-notify "$NOTIFY_NAME" "the instance still owns $NOTIFY_NAME after one reload"

notify phase2
check_match "phase-2 Notify returns an id" "$BUS_OUT" '^\(uint32 [0-9]+,\)$'

# The fresh state starts the counter over, so one call means one delivery.
check_eval hr-notify "phase-2 notification reached this compositor" \
    'return tostring(NOTIF_COUNT)' 1

# A second reload, because the state being torn down this time is itself a
# rebuilt one, and because name ownership now changes hands on a connection that
# outlives every state. Both of those first happen here, not on reload one.
sw_reload hr-notify || finish

check_bus_owner hr-notify "$NOTIFY_NAME" "the instance still owns $NOTIFY_NAME after two reloads"

notify phase3
check_match "phase-3 Notify returns an id" "$BUS_OUT" '^\(uint32 [0-9]+,\)$'
check_eval hr-notify "phase-3 notification reached this compositor" \
    'return tostring(NOTIF_COUNT)' 1

sw_check_log_clean hr-notify

finish
