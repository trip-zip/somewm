local wibox = require("wibox")
local beautiful = require("beautiful")
local broker = require("fishlive.broker")
local wh = require("fishlive.widget_helper")

local M = {}

function M.create(screen, config)
	local color = beautiful.widget_memory_color or "#d3869b"
	local icon = wibox.widget.textbox()
	local text = wibox.widget.textbox()

	local widget = wibox.widget {
		icon, text,
		layout = wibox.layout.fixed.horizontal,
	}

	broker.connect_signal("data::memory", function(data)
		icon.markup = wh.icon_markup(data.icon, color)
		local used_g = data.used / 1024
		local total_g = data.total / 1024
		text.markup = wh.text_markup(
			string.format("%.1f/%.0f GB", used_g, total_g), color)
	end)

	return widget
end

return M
