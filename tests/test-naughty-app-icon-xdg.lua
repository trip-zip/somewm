-- Test: app_icon XDG name resolution.
--
-- The request::icon signal fires with context "app_icon" for notifications
-- that provide an XDG icon name. A default handler should resolve these
-- names via menubar.utils.lookup_icon.

local naughty = require("naughty")
local notification = require("naughty.notification")
local menubar_utils = require("menubar.utils")
local runner = require("_runner")

-- Register a display handler so notifications are "shown"
naughty.connect_signal("request::display", function(n)
    require("naughty.layout.box") { notification = n }
end)

local steps = {}

-- Test that the app_icon handler resolves known XDG icons.
table.insert(steps, function()
    -- Find an icon that actually exists in this environment
    local test_icon_name = nil
    for _, name in ipairs({"utilities-terminal", "application-x-executable", "text-x-generic"}) do
        if menubar_utils.lookup_icon(name) then
            test_icon_name = name
            break
        end
    end

    if not test_icon_name then
        io.stderr:write("[SKIP] test-naughty-app-icon-xdg: no XDG icons found\n")
        return true
    end

    local n = notification {
        title    = "app_icon XDG test",
        text     = "app_icon should resolve to a path",
        app_icon = test_icon_name,
        timeout  = 0,
    }

    assert(n, "notification was not created")

    -- The icon should have been resolved by the app_icon handler
    assert(n.icon ~= nil,
        string.format(
            "app_icon '%s' was not resolved to an icon path - "..
            "no default handler for 'app_icon' context in core.lua",
            test_icon_name))

    n:destroy()
    return true
end)

-- Test that dominated icons (image-missing, etc.) are skipped.
table.insert(steps, function()
    local n = notification {
        title    = "app_icon dominated test",
        text     = "image-missing should not resolve",
        app_icon = "image-missing",
        timeout  = 0,
    }

    assert(n, "notification was not created")
    -- image-missing is in the dominated list, so the handler should skip it.
    assert(n.icon == nil,
        "dominated icon 'image-missing' should not have been resolved")

    n:destroy()
    return true
end)

runner.run_steps(steps, { kill_clients = false })
