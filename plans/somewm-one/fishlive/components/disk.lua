local wibox = require("wibox")
local beautiful = require("beautiful")
local broker = require("fishlive.broker")
local wh = require("fishlive.widget_helper")

local M = {}

function M.create(screen, config)
	local color = beautiful.widget_disk_color or "#e2b55a"
	local icon = wibox.widget.textbox()
	local text = wibox.widget.textbox()

	local widget = wibox.widget {
		icon, text,
		layout = wibox.layout.fixed.horizontal,
	}

	broker.connect_signal("data::disk", function(data)
		icon.markup = wh.icon_markup(data.icon, color)
		text.markup = wh.text_markup(
			string.format("%s/%s GB %2d%%", data.used, data.total, data.percent), color)
	end)

	return widget
end

return M
