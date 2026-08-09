#!/usr/bin/env bash
#
# Every org.freedesktop.Notifications call must get a reply. An unanswered
# invocation freezes the sender until the D-Bus timeout (~25s), which is how
# issue 657 presented. Covers the paths that used to drop the invocation:
# a Lua error inside a handler, an unknown method, and a Notify with nothing
# to display.

. "$(dirname "$0")/lib.sh"

skip_unless_bus

NOTIFY_NAME=org.freedesktop.Notifications
NOTIFY_PATH=/org/freedesktop/Notifications

sw_start notify-reply --config "$RESTART_DIR/configs/rc-dbus.lua" || finish

skip_unless_bus_owner notify-reply "$NOTIFY_NAME"

# notify-send-shaped call: urgency hint, no expiry.
sw_bus_call "$NOTIFY_NAME" "$NOTIFY_PATH" "$NOTIFY_NAME.Notify" \
    somewm-test 0 "" title body "[]" "{'urgency': <byte 1>}" -- -1
check_match "Notify with hints returns an id" "$BUS_OUT" '^\(uint32 [0-9]+,\)$'
check_eval notify-reply "notification reached this compositor" \
    'return tostring(NOTIF_COUNT)' 1

# Nothing to display, but the invocation still needs a reply.
sw_bus_call "$NOTIFY_NAME" "$NOTIFY_PATH" "$NOTIFY_NAME.Notify" \
    somewm-test 0 "" "" "" "[]" "{}" 2000
check_match "empty Notify still returns an id" "$BUS_OUT" '^\(uint32 [0-9]+,\)$'
check_eval notify-reply "empty Notify displays nothing" \
    'return tostring(NOTIF_COUNT)' 1

# Unknown method gets an error reply, not silence.
sw_bus_call "$NOTIFY_NAME" "$NOTIFY_PATH" "$NOTIFY_NAME.NoSuchMethod" \
    && fail "unknown method must not succeed" "$BUS_OUT"
check_match "unknown method returns UnknownMethod" "$BUS_OUT" 'UnknownMethod'

sw_check_log_clean notify-reply

# A handler error must become an instant error reply. Injected last: the
# traceback it prints would trip the log-clean check above.
sw_eval notify-reply 'require("naughty").get_by_id = function() error("boom657") end; return "ok"' \
    || fail "could not inject handler error" "$EVAL_ERROR"
sw_bus_call "$NOTIFY_NAME" "$NOTIFY_PATH" "$NOTIFY_NAME.Notify" \
    somewm-test 1 "" title body "[]" "{}" 2000 \
    && fail "Notify with broken handler must not succeed" "$BUS_OUT"
check_match "handler error returns a D-Bus error, not a timeout" "$BUS_OUT" 'boom657'

finish
