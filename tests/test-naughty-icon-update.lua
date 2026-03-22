-- Test: Notification icon not cleared on update.
--
-- icon_changed_callback only calls set_image(icn) when icn is truthy.
-- When the icon becomes nil, the old image persists in the widget
-- because set_image(nil) is never called.

local naughty = require("naughty")
local notification = require("naughty.notification")
local icon_widget = require("naughty.widget.icon")
local gsurface = require("gears.surface")
local cairo = require("lgi").cairo
local runner = require("_runner")

-- Register a display handler so notifications are "shown"
naughty.connect_signal("request::display", function(n)
    require("naughty.layout.box") { notification = n }
end)

local n = nil
local widget = nil

-- Create a small test icon surface
local function make_test_icon()
    local surface = cairo.ImageSurface.create(cairo.Format.ARGB32, 16, 16)
    local cr = cairo.Context(surface)
    cr:set_source_rgba(1, 0, 0, 1)
    cr:paint()
    return surface
end

local steps = {}

-- Step 1: Create a notification with an icon and an icon widget
table.insert(steps, function()
    local test_icon = make_test_icon()

    n = notification {
        title   = "icon update test",
        text    = "Icon should clear when set to nil",
        icon    = test_icon,
        timeout = 0,
    }

    assert(n, "notification was not created")
    assert(n.icon, "notification should have an icon")

    -- Create the icon widget bound to this notification
    widget = icon_widget { notification = n }

    assert(widget, "icon widget was not created")

    return true
end)

-- Step 2: Verify the widget has an image set
table.insert(steps, function()
    local current_image = widget._private.image

    assert(current_image ~= nil,
        "icon widget should have an image after creation")

    return true
end)

-- Step 3: Clear the notification's icon and verify the widget updates
table.insert(steps, function()
    -- Clear the icon
    n._private.icon = nil
    n:emit_signal("property::icon")

    return true
end)

-- Step 4: Assert the widget image was cleared
table.insert(steps, function()
    local current_image = widget._private.image

    assert(current_image == nil,
        "icon widget still shows old image after notification "..
        "icon was set to nil - icon_changed_callback only calls "..
        "set_image when new icon is truthy, never clears it")

    return true
end)

-- Cleanup
table.insert(steps, function()
    if n and not n._private.is_destroyed then
        n:destroy()
    end
    return true
end)

runner.run_steps(steps, { kill_clients = false })
