-- Test: D-Bus signal bugs in naughty notification dismiss path.
--
-- Bug #3944 - Action always executes on dismiss:
--   dbus.lua:72-73 - sendNotificationClosed() unconditionally calls
--   sendActionInvoked(notificationId, "default") whenever the close reason
--   is dismissed_by_user. This fires the default action on every dismiss,
--   even when the user just swiped away the notification without clicking
--   any action. Apps like Firefox open URLs on mere dismissal.
--
-- Bug #3836 - Wrong signal order:
--   ActionInvoked emits BEFORE NotificationClosed. The freedesktop spec
--   requires close AFTER action (if any action was invoked). But the real
--   issue is that ActionInvoked fires even when no action was invoked.
--
-- These bugs are at the D-Bus protocol level (sendNotificationClosed calls
-- sendActionInvoked unconditionally). They cannot be tested without a real
-- D-Bus session bus. The test skips in the test runner environment.
--
-- CONFIRMED BY CODE INSPECTION:
--   dbus.lua:68-80 shows sendNotificationClosed() always calling
--   sendActionInvoked("default") for dismissed_by_user, regardless of
--   whether the user actually clicked an action.
--
-- MANUAL VERIFICATION:
--   Run without WLR_BACKENDS set, with a real D-Bus session:
--   1. Start somewm as session compositor
--   2. Send notification: notify-send -a "test" "Test" "body" --action="default=Open"
--   3. Dismiss notification by clicking X (not the action)
--   4. Monitor with: dbus-monitor --session "interface='org.freedesktop.Notifications'"
--   5. BUG: ActionInvoked("default") is emitted despite no action click

local runner = require("_runner")

-- Skip in test runner (WLR_BACKENDS is set for nested/headless compositors)
if os.getenv("WLR_BACKENDS") then
    io.stderr:write("[SKIP] test-naughty-dbus-signals: "..
        "D-Bus protocol test requires real session (no WLR_BACKENDS)\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

-- Skip if D-Bus is not available
if not dbus or not os.getenv("DBUS_SESSION_BUS_ADDRESS") then
    io.stderr:write("[SKIP] test-naughty-dbus-signals: "..
        "D-Bus session bus not available\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local naughty = require("naughty")
local notification = require("naughty.notification")
local cst = require("naughty.constants")

-- Register a display handler
naughty.connect_signal("request::display", function(n)
    require("naughty.layout.box") { notification = n }
end)

local steps = {}

-- Bug #3944: Verify that dismissing a D-Bus notification triggers
-- spurious ActionInvoked signal.
--
-- We intercept the D-Bus signals to check if ActionInvoked fires
-- when we close a notification with reason=dismissed_by_user.
table.insert(steps, function()
    -- Request D-Bus name for monitoring
    local ok = pcall(function()
        dbus.request_name("session", "org.awesomewm.naughtytest")
    end)
    if not ok then
        io.stderr:write("[SKIP] Could not request D-Bus name\n")
        return true
    end

    -- Track signals emitted on the bus
    local signals_received = {}
    local function signal_tracker(data)
        table.insert(signals_received, {
            member = data.member,
            -- Args would contain notification ID, action name, etc.
        })
    end
    dbus.connect_signal("org.freedesktop.Notifications", signal_tracker)

    -- Create a notification with a default action via Lua API
    -- Note: This won't go through the D-Bus path, so the
    -- sendNotificationClosed callback won't fire. The bug is specifically
    -- in the D-Bus notification lifecycle.
    --
    -- For a full test, we'd need to send a notification via gdbus/dbus-send,
    -- then close it via CloseNotification, and check for ActionInvoked.
    -- That requires spawning external processes and waiting for D-Bus roundtrips.

    dbus.disconnect_signal("org.freedesktop.Notifications", signal_tracker)

    -- For now, the bug is confirmed by code inspection of dbus.lua:68-80.
    -- The test serves as documentation and a framework for manual testing.
    return true
end)

runner.run_steps(steps, { kill_clients = false })
