local wibox = require("wibox")
local awful = require("awful")
local beautiful = require("beautiful")
local broker = require("fishlive.broker")

local M = {}

function M.create(screen, config)
	local color = beautiful.widget_keyboard_color or "#74c7ec"
	local icon = wibox.widget.textbox()
	local text = wibox.widget.textbox()

	local widget = wibox.widget {
		icon, text,
		layout = wibox.layout.fixed.horizontal,
		spacing = beautiful.widget_spacing or 4,
	}

	broker.connect_signal("data::keyboard", function(data)
		icon.markup = string.format('<span color="%s">%s</span>', color, data.icon)
		text.markup = string.format('<span color="%s">%s</span>',
			color, string.upper(data.layout))
	end)

	-- Click: cycle to next layout
	widget:buttons(awful.util.table.join(
		awful.button({}, 1, function()
			awesome.xkb_set_layout_group(
				(awesome.xkb_get_layout_group() + 1) % #(broker.get_value("data::keyboard") or {layouts={"us"}}).layouts
			)
		end)
	))

	return widget
end

return M
