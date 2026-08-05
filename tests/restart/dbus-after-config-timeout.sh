#!/usr/bin/env bash
#
# After a config timeout, incoming D-Bus must still be dispatched.
#
# The timeout path runs the stale-source sweep before the baseline has been
# recorded: luaA_loadrc() runs at somewm.c:918 and the baseline is recorded at
# somewm.c:1036. With baseline=0 the sweep destroys everything, including the
# libdbus watch GSources attached in setup() (dbus.c:652). The connection stays
# up and the name stays owned, so the failure is invisible from the bus
# directory; it only shows as replies that never arrive. That also kills the
# PrepareForSleep hook.
#
# Ownership is checked first and is expected to pass: if the name were missing,
# the fallback config never ran and the reply assertion would mean nothing.
#
# Every bus call is wrapped in a timeout by sw_bus. Without it this test would
# hang rather than fail, the same invisibility that kept the old suite green.

# xfail: the config-timeout sweep runs with baseline=0 and destroys the libdbus watch sources

. "$(dirname "$0")/lib.sh"

skip_unless_bus

AWFUL_NAME=org.awesomewm.awful

sw_start_hung_config hr-timeoutbus || finish

check_bus_owner hr-timeoutbus "$AWFUL_NAME" "the instance owns $AWFUL_NAME after the fallback loaded"

sw_bus_call "$AWFUL_NAME" / "$AWFUL_NAME.Remote.Eval" 'return 40+2'
rc=$?
if [ $rc -eq 124 ]; then
    fail "remote eval replies after a config timeout" \
         "no reply within 5s: incoming D-Bus is never dispatched"
else
    check "remote eval replies after a config timeout" "$BUS_OUT" "(42.0,)"
fi

sw_report_sweep hr-timeoutbus

finish
