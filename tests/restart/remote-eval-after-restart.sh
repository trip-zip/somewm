#!/usr/bin/env bash
#
# awesome-client (the libdbus remote eval interface) must still work after a
# hot-reload.
#
# dbus_signals (dbus.c:59) holds Lua registry refs from the old state and is
# never reset. Re-registration is refused ("already existing"), and dispatch
# pushes the stale pointer into the new state and gets nil.
#
# The check must be an external call: the state holding the stale table cannot
# report on itself. And it must compare stdout, not the exit status: the broken
# case returns empty output with exit 0, so an exit-status test would pass while
# remote eval is completely dead.

. "$(dirname "$0")/lib.sh"

skip_unless_bus

AWFUL_NAME=org.awesomewm.awful

sw_start hr-remote --config "$ROOT_DIR/tests/rc.lua" || finish

check_eval hr-remote "the compositor has libdbus support" \
    'return tostring(dbus ~= nil)' true

inst_pid=$(sw_pid hr-remote)
owner_pid=$(sw_bus_owner_pid "$AWFUL_NAME") || skip "$AWFUL_NAME has no owner before the reload"
[ "$owner_pid" = "$inst_pid" ] || skip "$AWFUL_NAME owned by pid $owner_pid, not the instance ($inst_pid)"
pass "the instance owns $AWFUL_NAME before the reload"

remote_eval() {
    sw_bus_call "$AWFUL_NAME" / "$AWFUL_NAME.Remote.Eval" "$1"
}

remote_eval 'return 40+2'
check "phase-1 remote eval returns 42" "$BUS_OUT" "(42.0,)"

sw_reload hr-remote || finish

check_bus_owner hr-remote "$AWFUL_NAME" "the instance still owns $AWFUL_NAME after the reload"

remote_eval 'return 40+2'
check "phase-2 remote eval returns 42" "$BUS_OUT" "(42.0,)"

# Diagnostics only, never asserted; the fix is pinned by the eval probes above.
log_has hr-remote "already existing" && \
    info "log: re-registration of the Remote signal was refused"
log_has hr-remote "attempt to call a nil value" && \
    info "log: dispatch found nil at the stale registry slot"

sw_check_log_clean hr-remote

finish
