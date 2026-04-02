local wibox = require("wibox")
local beautiful = require("beautiful")
local broker = require("fishlive.broker")
local wh = require("fishlive.widget_helper")

local M = {}

function M.create(screen, config)
	local color = beautiful.widget_gpu_color or "#98c379"
	local icon = wibox.widget.textbox()
	local text = wh.fixed_text(90)

	local widget = wibox.widget {
		icon, text,
		layout = wibox.layout.fixed.horizontal,
	}

	broker.connect_signal("data::gpu", function(data)
		icon.markup = wh.icon_markup(data.icon, color)
		text._textbox.markup = wh.text_markup(
			string.format("%3d%% %2d°C", data.usage, data.temp), color)
	end)

	return widget
end

return M
