local wibox = require("wibox")
local beautiful = require("beautiful")
local broker = require("fishlive.broker")
local wh = require("fishlive.widget_helper")

local M = {}

function M.create(screen, config)
	local color = beautiful.widget_gpu_color or "#98c379"
	local icon = wibox.widget.textbox()
	local text = wibox.widget.textbox()

	local widget = wibox.widget {
		icon, text,
		layout = wibox.layout.fixed.horizontal,
		spacing = 2,
	}

	broker.connect_signal("data::gpu", function(data)
		icon.markup = wh.icon_markup(data.icon, color)
		text.markup = wh.text_markup(
			string.format("%3d%% %2d°C", data.usage, data.temp), color)
	end)

	return widget
end

return M
