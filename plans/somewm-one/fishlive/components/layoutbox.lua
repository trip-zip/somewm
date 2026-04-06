local wibox = require("wibox")
local awful = require("awful")

local M = {}

function M.create(screen, config)
	local layoutbox = awful.widget.layoutbox {
		screen = screen,
	}

	layoutbox:buttons(awful.util.table.join(
		awful.button({}, 1, function() awful.layout.inc(1) end),
		awful.button({}, 3, function() awful.layout.inc(-1) end),
		awful.button({}, 4, function() awful.layout.inc(-1) end),
		awful.button({}, 5, function() awful.layout.inc(1) end)
	))

	return layoutbox
end

return M
