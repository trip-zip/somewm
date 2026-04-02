local wibox = require("wibox")
local awful = require("awful")
local beautiful = require("beautiful")
local broker = require("fishlive.broker")

local M = {}

function M.create(screen, config)
	local color = beautiful.widget_updates_color or "#fab387"
	local icon = wibox.widget.textbox()
	local text = wibox.widget.textbox()

	local widget = wibox.widget {
		icon, text,
		layout = wibox.layout.fixed.horizontal,
		spacing = beautiful.widget_spacing or 4,
	}

	broker.connect_signal("data::updates", function(data)
		icon.markup = string.format('<span color="%s">%s</span>', color, data.icon)
		if data.total > 0 then
			text.markup = string.format('<span color="%s">%d</span>', color, data.total)
		else
			text.markup = string.format('<span color="%s">0</span>', color)
		end
	end)

	-- Click: open terminal with update command
	widget:buttons(awful.util.table.join(
		awful.button({}, 1, function()
			awful.spawn(string.format("%s -e paru",
				beautiful.terminal or "alacritty"))
		end)
	))

	return widget
end

return M
