dofile(assert(os.getenv("SOMEWM_TEST_BASE_RC"),
    "SOMEWM_TEST_BASE_RC must point at the base config to load"))

local wibox = require("wibox")
local shape = require("gears.shape")

-- A popup shown once and then hidden, still referenced from Lua.
hidden_popup = wibox {
    x = 10, y = 10, width = 100, height = 40, visible = true,
    widget = {
        shape = shape.star, bg = "#ff0000",
        widget = wibox.container.background,
    },
}
