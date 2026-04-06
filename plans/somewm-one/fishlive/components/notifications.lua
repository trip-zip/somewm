---------------------------------------------------------------------------
--- Notifications component — naughty config + display with rubato fade-in.
--
-- Auto-initializes on require (like services). All theme values are read
-- dynamically from beautiful at display time, so colorscheme changes
-- take effect immediately for new notifications.
--
-- Usage from rc.lua:
--   require("fishlive.components.notifications")
--
-- @module fishlive.components.notifications
-- @author Antonin Fischer (raven2cz) & Claude
-- @copyright 2026 MIT License
---------------------------------------------------------------------------

local naughty   = require("naughty")
local wibox     = require("wibox")
local gears     = require("gears")
local beautiful = require("beautiful")
local ruled     = require("ruled")
local rubato    = require("fishlive.rubato")
local dpi       = beautiful.xresources.apply_dpi

local M = {}

--- Resolve icon for display without modifying n.icon (avoids signal loops).
local function resolve_icon(n)
	local icon = n.icon
	if type(icon) == "string" then
		if icon == "" or icon:sub(1, 1) ~= "/" then
			return beautiful.notification_icon_default
		end
	elseif not icon then
		return beautiful.notification_icon_default
	end
	return icon
end

--- Create rubato fade-in animation for a notification popup.
local function fade_in(popup, config)
	config = config or {}
	local duration = config.fade_in_duration or 0.225
	local intro = config.fade_in_intro or 0.06

	popup.opacity = 0

	local anim = rubato.timed {
		pos            = 0,
		rate           = 60,
		duration       = duration,
		intro          = intro,
		easing         = rubato.easing.quadratic,
		clamp_position = true,
		subscribed     = function(pos)
			if popup.valid ~= false then
				popup.opacity = pos
			end
		end,
	}
	anim.target = 1
	return anim
end

--- Build the widget template for notification display.
-- Reads beautiful.* dynamically (called per notification).
local function build_widget_template(display_icon)
	return {
		{
			{
				{
					{
						{
							image          = display_icon,
							resize         = true,
							upscale        = true,
							forced_width   = dpi(128),
							forced_height  = dpi(128),
							clip_shape     = function(cr, w, h)
								gears.shape.rounded_rect(cr, w, h, dpi(4))
							end,
							widget         = wibox.widget.imagebox,
						},
						halign = "center",
						valign = "center",
						widget = wibox.container.place,
					},
					forced_width  = dpi(128),
					forced_height = dpi(128),
					widget        = wibox.container.constraint,
				},
				{
					{
						{
							align  = "left",
							font   = beautiful.font or "sans bold 14",
							widget = naughty.widget.title,
						},
						{
							align  = "left",
							widget = naughty.widget.message,
						},
						spacing = dpi(4),
						layout  = wibox.layout.fixed.vertical,
					},
					top    = dpi(8),
					widget = wibox.container.margin,
				},
				spacing = dpi(16),
				layout  = wibox.layout.fixed.horizontal,
			},
			margins = dpi(16),
			widget  = wibox.container.margin,
		},
		id     = "background_role",
		widget = naughty.container.background,
	}
end

---------------------------------------------------------------------------
-- Auto-initialization (runs once on first require)
---------------------------------------------------------------------------

-- Naughty defaults
naughty.config.defaults.ontop = true
naughty.config.defaults.icon_size = dpi(360)
naughty.config.defaults.timeout = 10
naughty.config.defaults.hover_timeout = 300
naughty.config.defaults.margin = dpi(16)
naughty.config.defaults.border_width = 0
naughty.config.defaults.position = "top_middle"
naughty.config.defaults.shape = function(cr, w, h)
	gears.shape.rounded_rect(cr, w, h, dpi(6))
end

naughty.config.padding = dpi(8)
naughty.config.spacing = dpi(8)
naughty.config.icon_dirs = {
	"/usr/share/icons/Papirus-Dark/",
	"/usr/share/icons/Tela/",
	"/usr/share/icons/Adwaita/",
	"/usr/share/icons/hicolor/",
}
naughty.config.icon_formats = { "svg", "png", "jpg", "gif" }

-- Rules read beautiful.* dynamically via request::rules signal
ruled.notification.connect_signal("request::rules", function()
	ruled.notification.append_rule {
		rule       = { urgency = "critical" },
		properties = {
			font             = beautiful.font,
			bg               = beautiful.bg_urgent or "#cc2233",
			fg               = "#ffffff",
			margin           = dpi(16),
			icon_size        = dpi(360),
			position         = "top_middle",
			implicit_timeout = 0,
		}
	}
	ruled.notification.append_rule {
		rule       = { urgency = "normal" },
		properties = {
			font             = beautiful.font,
			bg               = beautiful.notification_bg,
			fg               = beautiful.notification_fg,
			margin           = dpi(16),
			position         = "top_middle",
			implicit_timeout = 10,
			icon_size        = dpi(360),
		}
	}
	ruled.notification.append_rule {
		rule       = { urgency = "low" },
		properties = {
			font             = beautiful.font,
			bg               = beautiful.notification_bg,
			fg               = beautiful.notification_fg,
			margin           = dpi(16),
			position         = "top_middle",
			implicit_timeout = 8,
			icon_size        = dpi(360),
		}
	}
end)

-- Display handler with rubato fade-in
naughty.connect_signal("request::display", function(n)
	local display_icon = resolve_icon(n)

	local popup = naughty.layout.box {
		notification = n,
		shape = function(cr, w, h)
			gears.shape.rounded_rect(cr, w, h, dpi(6))
		end,
		widget_template = build_widget_template(display_icon),
	}

	if popup then
		-- Set opacity to 0 immediately, then start fade-in on next tick
		-- (ensures naughty finished its popup initialization)
		popup.opacity = 0
		gears.timer.delayed_call(function()
			fade_in(popup)
		end)
	end
end)

-- Export internals for testing
M._resolve_icon = resolve_icon
M._fade_in = fade_in
M._build_widget_template = build_widget_template

return M
