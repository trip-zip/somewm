---------------------------------------------------------------------------
--- Exit screen — fullscreen power/session overlay.
--
-- Shows Poweroff, Reboot, Suspend, Refresh, Exit, Lock buttons with
-- keyboard shortcuts. Themeable via beautiful.exit_screen_* properties.
--
-- Usage:
--   require("fishlive.exit_screen").init()
--   -- Bind toggle:
--   awful.key({ modkey }, "Escape", function()
--       awesome.emit_signal("exit_screen::toggle")
--   end)
--
-- @module fishlive.exit_screen
---------------------------------------------------------------------------

local awful = require("awful")
local gears = require("gears")
local wibox = require("wibox")
local beautiful = require("beautiful")
local dpi = require("beautiful.xresources").apply_dpi

local M = {}

-- State
local initialized = false
local exit_wb = nil
local grabber = nil

-- Config (populated in init)
local cfg = {}

local function resolve_config(opts)
	opts = opts or {}
	local c = {}
	c.bg_color        = opts.bg_color        or beautiful.exit_screen_bg        or (beautiful.bg_normal or "#181818") .. "dd"
	c.fg_color        = opts.fg_color        or beautiful.exit_screen_fg        or beautiful.fg_focus or "#d4d4d4"
	c.icon_color      = opts.icon_color      or beautiful.exit_screen_icon      or beautiful.border_color_active or "#e2b55a"
	c.icon_hover      = opts.icon_hover      or beautiful.exit_screen_icon_hover or beautiful.fg_urgent or "#e06c75"
	c.font            = opts.font            or beautiful.exit_screen_font      or "Geist 18"
	c.icon_font       = opts.icon_font       or beautiful.exit_screen_icon_font or "CommitMono Nerd Font 64"
	c.title_font      = opts.title_font      or beautiful.exit_screen_title_font or "Geist Bold 42"
	c.bg_image        = opts.bg_image        or beautiful.exit_screen_bg_image  or false
	c.bg_image_overlay = opts.bg_image_overlay or beautiful.exit_screen_bg_image_overlay or "#000000cc"
	return c
end

-- Highlight the shortcut letter in a label string.
-- E.g. highlight_shortcut("Poweroff", "P", accent, fg) → "<span>P</span>oweroff"
local function highlight_label(label, key, accent_color, fg_color)
	local i = label:lower():find(key:lower(), 1, true)
	if i then
		local before = label:sub(1, i - 1)
		local letter = label:sub(i, i)
		local after = label:sub(i + 1)
		return string.format(
			'<span foreground="%s">%s</span><span foreground="%s"><b>%s</b></span><span foreground="%s">%s</span>',
			fg_color, before, accent_color, letter, fg_color, after
		)
	end
	return string.format('<span foreground="%s">%s</span>', fg_color, label)
end

-- Build a single action button
local function make_button(icon, label, shortcut_key, action)
	local icon_widget = wibox.widget({
		markup = string.format('<span foreground="%s">%s</span>', cfg.icon_color, icon),
		font = cfg.icon_font,
		halign = "center",
		widget = wibox.widget.textbox,
	})

	local label_markup = highlight_label(label, shortcut_key:upper(), cfg.icon_color, cfg.fg_color)
	local label_widget = wibox.widget({
		markup = label_markup,
		font = cfg.font,
		halign = "center",
		widget = wibox.widget.textbox,
	})

	local btn = wibox.widget({
		{
			{
				icon_widget,
				{
					forced_height = dpi(12),
					widget = wibox.container.background,
				},
				label_widget,
				spacing = dpi(4),
				layout = wibox.layout.fixed.vertical,
			},
			margins = dpi(20),
			widget = wibox.container.margin,
		},
		forced_width = dpi(150),
		forced_height = dpi(170),
		bg = "transparent",
		shape = function(cr, w, h) gears.shape.rounded_rect(cr, w, h, dpi(12)) end,
		widget = wibox.container.background,
	})

	-- Hover effects
	btn:connect_signal("mouse::enter", function()
		icon_widget.markup = string.format('<span foreground="%s">%s</span>', cfg.icon_hover, icon)
		btn.bg = cfg.icon_color .. "20"
		local w = _G.mouse.current_wibox
		if w then w.cursor = "hand1" end
	end)
	btn:connect_signal("mouse::leave", function()
		icon_widget.markup = string.format('<span foreground="%s">%s</span>', cfg.icon_color, icon)
		btn.bg = "transparent"
		local w = _G.mouse.current_wibox
		if w then w.cursor = "left_ptr" end
	end)

	btn:buttons(gears.table.join(
		awful.button({}, 1, function()
			awesome.emit_signal("exit_screen::close")
			-- Defer action to let the screen close first
			gears.timer.start_new(0.1, function()
				action()
				return false
			end)
		end)
	))

	return btn
end

local function close()
	if exit_wb then exit_wb.visible = false end
	if grabber then
		grabber:stop()
		grabber = nil
	end
end

local function open()
	if not exit_wb then return end

	-- Update geometry to focused screen
	local s = awful.screen.focused()
	exit_wb.x = s.geometry.x
	exit_wb.y = s.geometry.y
	exit_wb.width = s.geometry.width
	exit_wb.height = s.geometry.height
	exit_wb.screen = s
	exit_wb.visible = true

	-- Actions table
	local actions = {
		p = function() awful.spawn.with_shell("systemctl poweroff") end,
		r = function() awful.spawn.with_shell("systemctl reboot") end,
		s = function() awful.spawn.with_shell("systemctl suspend") end,
		f = function() awesome.restart() end,
		e = function() awesome.quit() end,
		l = function() awesome.lock() end,
	}

	grabber = awful.keygrabber({
		autostart = true,
		stop_key = nil,
		mask_modkeys = true,
		keypressed_callback = function(_, _, key, _)
			if key == "Escape" or key == "q" or key == "x" then
				awesome.emit_signal("exit_screen::close")
			elseif actions[key] then
				awesome.emit_signal("exit_screen::close")
				gears.timer.start_new(0.1, function()
					actions[key]()
					return false
				end)
			end
		end,
	})
end

local function toggle()
	if exit_wb and exit_wb.visible then
		awesome.emit_signal("exit_screen::close")
	else
		awesome.emit_signal("exit_screen::open")
	end
end

--- Initialize the exit screen module.
-- @tparam[opt] table opts Configuration overrides
function M.init(opts)
	if initialized then return end
	initialized = true

	cfg = resolve_config(opts)

	-- Greeting
	local username = os.getenv("USER") or "user"
	local greeting = username:sub(1, 1):upper() .. username:sub(2)

	local title = wibox.widget({
		markup = string.format(
			'<span foreground="%s">Goodbye %s!</span>',
			cfg.fg_color, greeting
		),
		font = cfg.title_font,
		halign = "center",
		widget = wibox.widget.textbox,
	})

	-- Build buttons
	local poweroff = make_button("󰐥", "Poweroff", "P",
		function() awful.spawn.with_shell("systemctl poweroff") end)
	local reboot = make_button("󰜉", "Reboot", "R",
		function() awful.spawn.with_shell("systemctl reboot") end)
	local suspend = make_button("󰤄", "Suspend", "S",
		function() awful.spawn.with_shell("systemctl suspend") end)
	local refresh = make_button("󰑓", "Refresh", "F",
		function() awesome.restart() end)
	local exit = make_button("󰗼", "Exit", "E",
		function() awesome.quit() end)
	local lock = make_button("󰌾", "Lock", "L",
		function() awesome.lock() end)

	local buttons_row = wibox.widget({
		poweroff, reboot, suspend, refresh, exit, lock,
		spacing = dpi(24),
		layout = wibox.layout.fixed.horizontal,
	})

	local content = wibox.widget({
		{
			{
				title,
				{
					forced_height = dpi(40),
					widget = wibox.container.background,
				},
				{
					buttons_row,
					halign = "center",
					widget = wibox.container.place,
				},
				layout = wibox.layout.fixed.vertical,
			},
			halign = "center",
			valign = "center",
			widget = wibox.container.place,
		},
		bg = cfg.bg_image and cfg.bg_image_overlay or cfg.bg_color,
		widget = wibox.container.background,
	})

	-- Wrap with bg_image if set
	local root_widget = content
	if cfg.bg_image then
		local img = gears.surface.load_uncached_silently(cfg.bg_image)
		if img then
			root_widget = wibox.widget({
				{
					image = img,
					resize = true,
					horizontal_fit_policy = "fit",
					vertical_fit_policy = "fit",
					upscale = true,
					downscale = true,
					widget = wibox.widget.imagebox,
				},
				content,
				layout = wibox.layout.stack,
			})
		end
	end

	-- Create wibox on primary screen (will be repositioned on open)
	local s = screen.primary or screen[1]
	exit_wb = wibox({
		visible = false,
		ontop = true,
		type = "dock",
		bg = cfg.bg_image and "#00000000" or cfg.bg_color,
		x = s.geometry.x,
		y = s.geometry.y,
		width = s.geometry.width,
		height = s.geometry.height,
		widget = root_widget,
	})

	-- Close on right/middle click
	exit_wb:buttons(gears.table.join(
		awful.button({}, 2, function() awesome.emit_signal("exit_screen::close") end),
		awful.button({}, 3, function() awesome.emit_signal("exit_screen::close") end)
	))

	-- Signals
	awesome.connect_signal("exit_screen::open", open)
	awesome.connect_signal("exit_screen::close", close)
	awesome.connect_signal("exit_screen::toggle", toggle)
end

return M
