local wibox = require("wibox")
local awful = require("awful")
local beautiful = require("beautiful")
local broker = require("fishlive.broker")
local wh = require("fishlive.widget_helper")

local M = {}

function M.create(screen, config)
	local color = beautiful.widget_keyboard_color or "#7daea3"
	local widget, update = wh.create_icon_text(color)

	broker.connect_signal("data::keyboard", function(data)
		-- Extra leading space: keyboard is first widget, needs gap from taglist colors
		widget.markup = string.format(
			'<span> </span><span font="%s" foreground="%s">%s</span>' ..
			'<span font="%s" foreground="%s"> %s</span>',
			require("fishlive.widget_helper").icon_font, color, data.icon,
			require("fishlive.widget_helper").number_font, color, string.upper(data.layout))
	end)

	widget:buttons(awful.util.table.join(
		awful.button({}, 1, function()
			local data = broker.get_value("data::keyboard")
			if data and data.layouts then
				local count = #data.layouts
				if count > 0 then
					awesome.xkb_set_layout_group(
						(awesome.xkb_get_layout_group() + 1) % count)
				end
			end
		end)
	))

	return widget
end

return M
