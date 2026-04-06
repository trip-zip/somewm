---------------------------------------------------------------------------
--- Widget helper — fonts, separators, markup helpers.
--
-- Design rules:
-- 1. Icon font: Symbols Nerd Font Mono (fixed width, no half-cut)
-- 2. Number font: CommitMono Nerd Font Propo (monospace digits)
-- 3. Icon and text in same textbox via markup (no layout spacing issues)
-- 4. Fixed-width number formatting via string.format width specifiers
--
-- @module fishlive.widget_helper
---------------------------------------------------------------------------

local wibox = require("wibox")
local beautiful = require("beautiful")

local M = {}

M.icon_font = "Symbols Nerd Font Mono 12"
M.number_font = "CommitMono Nerd Font Propo 10"

--- Shadow params memo (for iterative tuning)
-- CURRENT:  radius=30, opacity=0.65, offset_y=5
-- TEST:     radius=40, opacity=0.85, offset_y=7
M.shadow_memo = {
	current = { radius = 30, opacity = 0.65, offset_x = 5, offset_y = 5 },
	test    = { radius = 40, opacity = 0.85, offset_x = 5, offset_y = 7 },
}

--- Create a widget with icon + text in a SINGLE textbox.
-- This avoids all spacing issues between separate icon/text widgets.
function M.create_icon_text(color)
	local tb = wibox.widget.textbox()
	return tb, function(icon, text)
		tb.markup = string.format(
			'<span font="%s" foreground="%s">%s</span>' ..
			'<span font="%s" foreground="%s"> %s</span>',
			M.icon_font, color, icon,
			M.number_font, color, text)
	end
end

--- Create a separator widget between components.
function M.separator()
	local sep = wibox.widget.textbox()
	sep.markup = string.format('<span color="%s"> │ </span>',
		beautiful.fg_minimize or "#555555")
	sep.font = beautiful.font or "Geist 10"
	return sep
end

return M
