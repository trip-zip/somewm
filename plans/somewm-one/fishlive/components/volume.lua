local wibox = require("wibox")
local awful = require("awful")
local beautiful = require("beautiful")
local broker = require("fishlive.broker")

local M = {}

function M.create(screen, config)
	local color = beautiful.widget_volume_color or "#f38ba8"
	local icon = wibox.widget.textbox()
	local text = wibox.widget.textbox()

	local widget = wibox.widget {
		icon, text,
		layout = wibox.layout.fixed.horizontal,
		spacing = beautiful.widget_spacing or 4,
	}

	broker.connect_signal("data::volume", function(data)
		icon.markup = string.format('<span color="%s">%s</span>', color, data.icon)
		text.markup = string.format('<span color="%s">%d%%</span>', color, data.volume)
	end)

	-- Click: toggle mute, scroll: volume up/down
	widget:buttons(awful.util.table.join(
		awful.button({}, 1, function()
			awful.spawn("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle")
		end),
		awful.button({}, 4, function()
			awful.spawn("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+")
		end),
		awful.button({}, 5, function()
			awful.spawn("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-")
		end)
	))

	return widget
end

return M
