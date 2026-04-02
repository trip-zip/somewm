---------------------------------------------------------------------------
--- Widget helper — fixed-width text, separators, Nerd Font icons.
--
-- @module fishlive.widget_helper
---------------------------------------------------------------------------

local wibox = require("wibox")
local beautiful = require("beautiful")

local M = {}

--- Nerd Font family for icons (Propo = proportional, no half-cut glyphs)
M.icon_font = "Symbols Nerd Font Mono 12"

--- Monospace font for numbers (prevents width jitter)
M.number_font = "CommitMono Nerd Font Propo 10"

--- Create a fixed-width textbox that doesn't shift neighbors.
-- @tparam number width Minimum width in characters (approximate)
-- @treturn widget Constrained textbox
function M.fixed_text(width)
	local tb = wibox.widget.textbox()
	-- force_width prevents layout shifts when text changes length
	local constraint = wibox.container.constraint(tb, "exact",
		width or 50, nil)
	constraint._textbox = tb
	return constraint
end

--- Create a separator widget between components.
function M.separator()
	local sep = wibox.widget.textbox()
	sep.markup = string.format('<span color="%s"> │ </span>',
		beautiful.fg_minimize or "#555555")
	sep.font = beautiful.font or "Geist 10"
	return sep
end

--- Format icon with correct Nerd Font.
function M.icon_markup(icon_char, color)
	return string.format('<span font="%s" color="%s">%s</span>',
		M.icon_font, color, icon_char)
end

--- Format number text with monospace font (no width jitter).
function M.text_markup(text, color)
	return string.format('<span font="%s" color="%s">%s</span>',
		M.number_font, color, text)
end

return M
