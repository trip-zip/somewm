local wibox = require("wibox")
local awful = require("awful")
local beautiful = require("beautiful")
local broker = require("fishlive.broker")
local wh = require("fishlive.widget_helper")

local M = {}

function M.create(screen, config)
	local color = beautiful.widget_volume_color or "#ea6962"
	local icon = wibox.widget.textbox()
	local text = wibox.widget.textbox()

	local widget = wibox.widget {
		icon, text,
		layout = wibox.layout.fixed.horizontal,
		spacing = 2,
	}

	broker.connect_signal("data::volume", function(data)
		icon.markup = wh.icon_markup(data.icon, color)
		text.markup = wh.text_markup(
			string.format("%3d%%", data.volume), color)
	end)

	widget:buttons(awful.util.table.join(
		awful.button({}, 1, function()
			awful.spawn.with_shell("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle &")
		end),
		awful.button({}, 4, function()
			awful.spawn.with_shell("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+ &")
		end),
		awful.button({}, 5, function()
			awful.spawn.with_shell("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%- &")
		end)
	))

	return widget
end

return M
