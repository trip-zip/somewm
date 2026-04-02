local wibox = require("wibox")
local awful = require("awful")
local beautiful = require("beautiful")

local M = {}

function M.create(screen, config)
	local color = beautiful.widget_clock_color or "#f5e0dc"
	local format = config.format or '<span color="%s">%s %%H:%%M</span>'
	local icon = "󰥔"

	local clock = wibox.widget.textclock(
		string.format(format, color, icon), 60)

	-- Calendar popup on click
	local cal_popup = nil

	clock:buttons(awful.util.table.join(
		awful.button({}, 1, function()
			if cal_popup and cal_popup.visible then
				cal_popup.visible = false
				return
			end

			if not cal_popup then
				cal_popup = awful.popup {
					widget = wibox.widget {
						date = os.date("*t"),
						font = beautiful.font or "monospace 10",
						widget = wibox.widget.calendar.month,
					},
					ontop = true,
					border_width = beautiful.border_width or 1,
					border_color = beautiful.border_focus or color,
					placement = function(d)
						awful.placement.top_right(d, {
							margins = { top = (beautiful.wibar_height or 28) + 4, right = 4 },
							parent = screen,
						})
					end,
				}
			else
				cal_popup.widget.date = os.date("*t")
			end
			cal_popup.visible = true
		end)
	))

	return clock
end

return M
