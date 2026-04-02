local wibox = require("wibox")
local beautiful = require("beautiful")
local broker = require("fishlive.broker")
local wh = require("fishlive.widget_helper")

local M = {}

function M.create(screen, config)
	local color = beautiful.widget_network_color or "#89b482"
	local widget = wibox.widget.textbox()

	broker.connect_signal("data::network", function(data)
		widget.markup = string.format(
			'<span font="%s" foreground="%s">%s</span>' ..
			'<span font="%s" foreground="%s"> %s </span>' ..
			'<span font="%s" foreground="%s">%s</span>' ..
			'<span font="%s" foreground="%s"> %s</span>',
			wh.icon_font, color, data.icon_down,
			wh.number_font, color, data.rx_formatted,
			wh.icon_font, color, data.icon_up,
			wh.number_font, color, data.tx_formatted)
	end)

	return widget
end

return M
