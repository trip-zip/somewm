---------------------------------------------------------------------------
-- @author somewm contributors
-- @copyright 2025 somewm contributors
--
-- Minimal configuration for integration tests
---------------------------------------------------------------------------

-- Minimal test configuration - just enough to run tests
-- No widgets, no wibar, no visual elements

pcall(require, "luarocks.loader")

local gears = require("gears")
local awful = require("awful")
require("awful.autofocus")

-- Default modkey
modkey = "Mod4"

-- Table of layouts
awful.layout.layouts = {
    awful.layout.suit.floating,
    awful.layout.suit.tile,
}

-- Create a tag for each screen
awful.screen.connect_for_each_screen(function(s)
    -- Each screen has its own tag table
    awful.tag({ "test" }, s, awful.layout.layouts[1])
end)

-- Disable error handling popups
awful.spawn = function() end

-- Redirect errors to stderr for test visibility
awesome.connect_signal("debug::error", function(err)
    io.stderr:write("ERROR: " .. tostring(err) .. "\n")
end)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
