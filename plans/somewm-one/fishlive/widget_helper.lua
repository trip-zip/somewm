---------------------------------------------------------------------------
--- Widget helper — fonts, separators, markup helpers.
--
-- @module fishlive.widget_helper
---------------------------------------------------------------------------

local wibox = require("wibox")
local beautiful = require("beautiful")

local M = {}

--- Nerd Font for icons (Mono variant = fixed width, no half-cut glyphs)
M.icon_font = "Symbols Nerd Font Mono 12"

--- Monospace font for numbers (consistent width, no jitter)
M.number_font = "CommitMono Nerd Font Propo 10"

--- Create a separator widget between components.
function M.separator()
	local sep = wibox.widget.textbox()
	sep.markup = string.format('<span color="%s"> │ </span>',
		beautiful.fg_minimize or "#555555")
	sep.font = beautiful.font or "Geist 10"
	return sep
end

--- Format icon with Nerd Font Mono (single space after for text gap).
function M.icon_markup(icon_char, color)
	return string.format('<span font="%s" foreground="%s">%s </span>',
		M.icon_font, color, icon_char)
end

--- Format text with monospace font (single space before for icon gap).
function M.text_markup(text, color)
	return string.format('<span font="%s" foreground="%s">%s</span>',
		M.number_font, color, text)
end

return M
