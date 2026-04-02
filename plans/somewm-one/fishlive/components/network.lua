local wibox = require("wibox")
local beautiful = require("beautiful")
local broker = require("fishlive.broker")
local wh = require("fishlive.widget_helper")

local M = {}

function M.create(screen, config)
	local color = beautiful.widget_network_color or "#89b482"
	local down_widget = wibox.widget {
		wibox.widget.textbox(), wibox.widget.textbox(),
		layout = wibox.layout.fixed.horizontal,
		spacing = 2,
	}
	local up_widget = wibox.widget {
		wibox.widget.textbox(), wibox.widget.textbox(),
		layout = wibox.layout.fixed.horizontal,
		spacing = 2,
	}

	local widget = wibox.widget {
		down_widget, up_widget,
		layout = wibox.layout.fixed.horizontal,
		spacing = 4,
	}

	broker.connect_signal("data::network", function(data)
		down_widget:get_children()[1].markup = wh.icon_markup(data.icon_down, color)
		down_widget:get_children()[2].markup = wh.text_markup(data.rx_formatted, color)
		up_widget:get_children()[1].markup = wh.icon_markup(data.icon_up, color)
		up_widget:get_children()[2].markup = wh.text_markup(data.tx_formatted, color)
	end)

	return widget
end

return M
