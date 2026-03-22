-- Test: Notification property fallback chain - beautiful theme variables.
--
-- The generic property getter only checks self._private[prop], preset[prop],
-- and cst.config.defaults[prop]. It never consults
-- beautiful["notification_"..prop], despite these being documented.

local naughty = require("naughty")
local notification = require("naughty.notification")
local beautiful = require("beautiful")
local runner = require("_runner")

-- Register a display handler so notifications are "shown"
naughty.connect_signal("request::display", function(n)
    require("naughty.layout.box") { notification = n }
end)

local n_border = nil

local steps = {}

-- Verify beautiful.notification_border_width is used by the getter.
table.insert(steps, function()
    -- Set the beautiful variables
    beautiful.notification_border_width = 42
    beautiful.notification_border_color = "#ff0000"

    n_border = notification {
        title = "beautiful border test",
        text  = "border_width should come from beautiful theme",
    }

    assert(n_border, "notification was not created")

    local bw = n_border.border_width
    assert(bw == 42,
        string.format(
            "expected border_width 42 from beautiful, got %s - "..
            "the generic getter never checks beautiful.notification_border_width",
            tostring(bw)))

    local bc = n_border.border_color
    assert(bc == "#ff0000",
        string.format(
            "expected border_color '#ff0000' from beautiful, got %s - "..
            "the generic getter never checks beautiful.notification_border_color",
            tostring(bc)))

    return true
end)

-- Cleanup
table.insert(steps, function()
    beautiful.notification_border_width = nil
    beautiful.notification_border_color = nil

    if n_border and not n_border._private.is_destroyed then
        n_border:destroy()
    end
    return true
end)

runner.run_steps(steps, { kill_clients = false })
