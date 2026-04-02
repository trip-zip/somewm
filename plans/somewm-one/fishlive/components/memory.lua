local wibox = require("wibox")
local beautiful = require("beautiful")
local broker = require("fishlive.broker")
local wh = require("fishlive.widget_helper")

local M = {}

function M.create(screen, config)
	local color = beautiful.widget_memory_color or "#d3869b"
	local icon = wibox.widget.textbox()
	local text = wh.fixed_text(70)

	local widget = wibox.widget {
		icon, text,
		layout = wibox.layout.fixed.horizontal,
	}

	broker.connect_signal("data::memory", function(data)
		icon.markup = wh.icon_markup(data.icon, color)
		-- Show in GB for readability
		local used_g = string.format("%.1f", data.used / 1024)
		local total_g = string.format("%.0f", data.total / 1024)
		text._textbox.markup = wh.text_markup(
			string.format("%sG/%sG", used_g, total_g), color)
	end)

	return widget
end

return M
