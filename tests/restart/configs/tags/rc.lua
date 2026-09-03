-- Three tags on every screen, for the hot-reload tag restore test.
--
-- A copy of tests/rc.lua rather than a dofile(SOMEWM_TEST_BASE_RC) layer like
-- the other configs here: the base already creates a tag per screen, so a
-- layer would have to delete it, and the test rewrites the tag list in this
-- file between reloads. tests/rc.lua keeps its single tag either way, which is
-- what every other test in the suite expects.

pcall(require, "luarocks.loader")

local awful = require("awful")
local ruled = require("ruled")
require("awful.autofocus")

awful.layout.layouts = {
    awful.layout.suit.floating,
    awful.layout.suit.tile,
}

awful.screen.connect_for_each_screen(function(s)
    awful.tag({ "1", "2", "3" }, s, awful.layout.layouts[1])
end)

-- Rebuild a known titlebar on floating clients so repeated reloads also prove
-- that discarding stale Lua drawables does not grow the preserved geometry.
ruled.client.connect_signal("request::rules", function()
    ruled.client.append_rule {
        rule = {},
        properties = { floating = true, titlebars_enabled = true },
    }
end)

client.connect_signal("request::titlebars", function(c)
    awful.titlebar(c, { size = 23, position = "top" })
end)

awesome.connect_signal("debug::error", function(err)
    io.stderr:write("ERROR: " .. tostring(err) .. "\n")
end)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
