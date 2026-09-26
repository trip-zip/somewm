dofile(assert(os.getenv("SOMEWM_TEST_BASE_RC"),
    "SOMEWM_TEST_BASE_RC must point at the base config to load"))

local awful = require("awful")
local wibox = require("wibox")
local shape = require("gears.shape")

awful.screen.connect_for_each_screen(function(s)
    s.shape_bar = awful.wibar {
        screen = s, position = "top", height = 32,
        widget = wibox.widget {
            layout = wibox.layout.align.horizontal,
            {
                layout = wibox.layout.fixed.horizontal,
                awful.widget.taglist { screen = s, filter = awful.widget.taglist.filter.all },
                {
                    shape = shape.circle, color = "#ffffff", forced_width = 32,
                    widget = wibox.widget.separator,
                },
            },
            awful.widget.tasklist { screen = s, filter = awful.widget.tasklist.filter.currenttags },
            wibox.widget.textclock("%H:%M"),
        },
    }
end)
