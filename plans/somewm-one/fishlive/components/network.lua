local wibox = require("wibox")
local beautiful = require("beautiful")
local broker = require("fishlive.broker")

local M = {}

function M.create(screen, config)
	local color = beautiful.widget_network_color or "#94e2d5"
	local icon_down = wibox.widget.textbox()
	local icon_up = wibox.widget.textbox()
	local text_down = wibox.widget.textbox()
	local text_up = wibox.widget.textbox()

	local widget = wibox.widget {
		icon_down, text_down,
		icon_up, text_up,
		layout = wibox.layout.fixed.horizontal,
		spacing = beautiful.widget_spacing or 4,
	}

	broker.connect_signal("data::network", function(data)
		icon_down.markup = string.format('<span color="%s">%s</span>', color, data.icon_down)
		text_down.markup = string.format('<span color="%s">%s</span>', color, data.rx_formatted)
		icon_up.markup = string.format('<span color="%s">%s</span>', color, data.icon_up)
		text_up.markup = string.format('<span color="%s">%s</span>', color, data.tx_formatted)
	end)

	return widget
end

return M
