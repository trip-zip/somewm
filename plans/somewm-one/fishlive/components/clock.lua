---------------------------------------------------------------------------
--- Clock component — dimmed date + accent time, calendar popup on click.
--
-- Preserves the original somewm-one clock style:
--   "Thu 02 Apr" in muted gray + "20:09" in warm amber
--
-- @module fishlive.components.clock
---------------------------------------------------------------------------

local wibox = require("wibox")
local awful = require("awful")
local gears = require("gears")
local beautiful = require("beautiful")

local M = {}

function M.create(screen, config)
	local date_color = config.date_color or "#b0b0b0"
	local time_color = config.time_color or beautiful.widget_clock_color or "#e2b55a"
	local date_font = config.date_font or beautiful.font or "Geist 10"
	local time_font = config.time_font or beautiful.font_large or "Geist SemiBold 11"

	local icon_font = require("fishlive.widget_helper").icon_font
	local clock = wibox.widget.textclock(
		'<span font="' .. icon_font .. '" foreground="' .. time_color .. '">󰥔 </span>' ..
		'<span foreground="' .. date_color .. '" font="' .. date_font .. '">%a %d %b </span>' ..
		'<span foreground="' .. time_color .. '" font="' .. time_font .. '">%H:%M</span>', 60
	)

	-- Calendar popup matching original somewm-one style
	local bg_base = beautiful.bg_normal or "#181818"
	local accent = time_color

	local cal_popup = awful.widget.calendar_popup.month({
		start_sunday = false,
		long_weekdays = true,
		style_month = {
			bg_color     = bg_base .. "f0",
			border_color = accent,
			border_width = 1,
			padding      = beautiful.useless_gap and beautiful.useless_gap * 3 or 10,
		},
		style_header = {
			fg_color     = accent,
			font         = time_font,
		},
		style_weekday = {
			fg_color     = date_color,
			font         = date_font,
		},
		style_normal = {
			fg_color     = beautiful.fg_focus or "#d4d4d4",
			font         = date_font,
		},
		style_focus = {
			fg_color     = bg_base,
			bg_color     = accent,
			font         = config.focus_font or "Geist Bold 10",
			shape        = gears.shape.circle,
		},
	})

	cal_popup:attach(clock, "tr", { on_hover = false })

	return clock
end

return M
