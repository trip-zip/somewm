local wibox = require("wibox")
local beautiful = require("beautiful")
local broker = require("fishlive.broker")
local wh = require("fishlive.widget_helper")

local M = {}

function M.create(screen, config)
	local color = beautiful.widget_network_color or "#89b482"
	local icon_down = wibox.widget.textbox()
	local text_down = wh.fixed_text(45)
	local icon_up = wibox.widget.textbox()
	local text_up = wh.fixed_text(45)

	local widget = wibox.widget {
		icon_down, text_down,
		icon_up, text_up,
		layout = wibox.layout.fixed.horizontal,
	}

	broker.connect_signal("data::network", function(data)
		icon_down.markup = wh.icon_markup(data.icon_down, color)
		text_down._textbox.markup = wh.text_markup(
			string.format("%5s", data.rx_formatted), color)
		icon_up.markup = wh.icon_markup(data.icon_up, color)
		text_up._textbox.markup = wh.text_markup(
			string.format("%5s", data.tx_formatted), color)
	end)

	return widget
end

return M
