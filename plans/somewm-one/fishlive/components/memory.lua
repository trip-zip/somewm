local wibox = require("wibox")
local beautiful = require("beautiful")
local broker = require("fishlive.broker")

local M = {}

function M.create(screen, config)
	local color = beautiful.widget_memory_color or "#cba6f7"
	local icon = wibox.widget.textbox()
	local text = wibox.widget.textbox()

	local widget = wibox.widget {
		icon, text,
		layout = wibox.layout.fixed.horizontal,
		spacing = beautiful.widget_spacing or 4,
	}

	broker.connect_signal("data::memory", function(data)
		icon.markup = string.format('<span color="%s">%s</span>', color, data.icon)
		text.markup = string.format('<span color="%s">%dM/%dM</span>',
			color, data.used, data.total)
	end)

	return widget
end

return M
