local wibox = require("wibox")
local awful = require("awful")
local beautiful = require("beautiful")
local broker = require("fishlive.broker")
local wh = require("fishlive.widget_helper")

local M = {}

function M.create(screen, config)
	local color = beautiful.widget_updates_color or "#d8a657"
	local icon = wibox.widget.textbox()
	local text = wibox.widget.textbox()

	local widget = wibox.widget {
		icon, text,
		layout = wibox.layout.fixed.horizontal,
		spacing = 2,
	}

	broker.connect_signal("data::updates", function(data)
		icon.markup = wh.icon_markup(data.icon, color)
		text.markup = wh.text_markup(tostring(data.total), color)
	end)

	widget:buttons(awful.util.table.join(
		awful.button({}, 1, function()
			awful.spawn(string.format("%s -e paru",
				beautiful.terminal or "ghostty"))
		end)
	))

	return widget
end

return M
