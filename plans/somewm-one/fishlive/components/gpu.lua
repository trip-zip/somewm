local wibox = require("wibox")
local beautiful = require("beautiful")
local broker = require("fishlive.broker")

local M = {}

function M.create(screen, config)
	local color = beautiful.widget_gpu_color or "#a6e3a1"
	local icon = wibox.widget.textbox()
	local text = wibox.widget.textbox()

	local widget = wibox.widget {
		icon, text,
		layout = wibox.layout.fixed.horizontal,
		spacing = beautiful.widget_spacing or 4,
	}

	broker.connect_signal("data::gpu", function(data)
		icon.markup = string.format('<span color="%s">%s</span>', color, data.icon)
		text.markup = string.format('<span color="%s">%d%% %d°C</span>',
			color, data.usage, data.temp)
	end)

	return widget
end

return M
