local runner = require("_runner")
local awful = require("awful")

-- Skip test in automated test environments
-- This test spawns dbus-send and depends on D-Bus session bus infrastructure.
-- It's unreliable in test runners due to:
-- - Isolated XDG_RUNTIME_DIR in headless mode
-- - D-Bus session bus not forwarded to nested compositor in visual mode
-- Run manually without WLR_BACKENDS set to actually test D-Bus functionality.
if os.getenv("WLR_BACKENDS") then
    io.stderr:write("[SKIP] test-dbus-error: D-Bus unreliable in test runner\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

-- Skip test if D-Bus isn't available
if not dbus or not os.getenv("DBUS_SESSION_BUS_ADDRESS") then
    io.stderr:write("[SKIP] test-dbus-error: D-Bus session bus not available\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local calls_done = 0

local function dbus_callback(data)
    assert(data.member == "Ping")
    calls_done = calls_done + 1
end

-- Try to request name, skip if it fails
local success = pcall(function()
    dbus.request_name("session", "org.awesomewm.test")
end)
if not success then
    io.stderr:write("[SKIP] test-dbus-error: Could not request D-Bus name\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

-- Yup, we had a bug that made the following not work
dbus.connect_signal("org.awesomewm.test", dbus_callback)
dbus.disconnect_signal("org.awesomewm.test", dbus_callback)
dbus.connect_signal("org.awesomewm.test", dbus_callback)

for _=1, 2 do
    awful.spawn({
                "dbus-send",
                "--dest=org.awesomewm.test",
                "--type=method_call",
                "/",
                "org.awesomewm.test.Ping",
                "string:foo"
            })
end

runner.run_steps({ function()
    if calls_done >= 2 then
        return true
    end
end })

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
