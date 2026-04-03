---------------------------------------------------------------------------
--- Exit screen — fullscreen power/session overlay.
--
-- Shows Poweroff, Reboot, Suspend, Refresh, Exit, Lock buttons with
-- keyboard shortcuts. Themeable via beautiful.exit_screen_* properties.
-- Uses rubato for smooth, interrupt-safe hover animations.
--
-- Usage:
--   require("fishlive.exit_screen").init()
--   -- Bind toggle:
--   awful.key({ modkey }, "q", function()
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
local rubato = require("fishlive.rubato")

local M = {}

-- Exported for testing
M._state = {
	initialized = false,
	exit_wb = nil,
	grabber = nil,
	cfg = {},
}

function M._reset()
	M._state.initialized = false
	M._state.exit_wb = nil
	M._state.grabber = nil
	M._state.cfg = {}
end

function M.resolve_config(opts)
	opts = opts or {}
	local c = {}
	c.bg_color         = opts.bg_color         or beautiful.exit_screen_bg             or (beautiful.bg_normal or "#181818") .. "dd"
	c.fg_color         = opts.fg_color         or beautiful.exit_screen_fg             or beautiful.fg_focus or "#d4d4d4"
	c.icon_color       = opts.icon_color       or beautiful.exit_screen_icon           or beautiful.border_color_active or "#e2b55a"
	c.icon_hover       = opts.icon_hover       or beautiful.exit_screen_icon_hover     or beautiful.fg_urgent or "#e06c75"
	c.font             = opts.font             or beautiful.exit_screen_font           or "Geist 14"
	c.icon_font        = opts.icon_font        or beautiful.exit_screen_icon_font      or "CommitMono Nerd Font 52"
	c.title_font       = opts.title_font       or beautiful.exit_screen_title_font     or "Geist Bold 42"
	c.bg_image         = opts.bg_image         or beautiful.exit_screen_bg_image       or false
	c.bg_image_overlay = opts.bg_image_overlay or beautiful.exit_screen_bg_image_overlay or "#000000cc"
	c.hover_bg         = opts.hover_bg         or beautiful.exit_screen_hover_bg       or false
	-- Rubato animation settings
	c.anim_duration    = opts.anim_duration    or 0.25  -- seconds
	c.anim_intro       = opts.anim_intro       or 0.08
	c.anim_outro       = opts.anim_outro       or 0.08
	return c
end

--- Highlight the shortcut letter in a label string.
-- @tparam string label Full label text (e.g. "Poweroff")
-- @tparam string key Shortcut key (e.g. "P" or "f")
-- @tparam string accent_color Color for the highlighted letter
-- @tparam string fg_color Color for the rest of the label
-- @treturn string Pango markup with highlighted shortcut
function M.highlight_label(label, key, accent_color, fg_color)
	local i = label:lower():find(key:lower(), 1, true)
	if i then
		local before = label:sub(1, i - 1)
		local letter = label:sub(i, i)
		local after = label:sub(i + 1)
		return string.format(
			'<span foreground="%s">%s</span>'
			.. '<span foreground="%s"><b><u>%s</u></b></span>'
			.. '<span foreground="%s">%s</span>',
			fg_color, before, accent_color, letter, fg_color, after
		)
	end
	return string.format('<span foreground="%s">%s</span>', fg_color, label)
end

--- Interpolate between two hex colors.
-- @tparam string c1 Start color "#RRGGBB"
-- @tparam string c2 End color "#RRGGBB"
-- @tparam number t Interpolation factor 0..1
-- @treturn string Interpolated color "#RRGGBB"
function M.lerp_color(c1, c2, t)
	local function hex(s, pos) return tonumber(s:sub(pos, pos + 1), 16) end
	local r = math.floor(hex(c1, 2) * (1 - t) + hex(c2, 2) * t + 0.5)
	local g = math.floor(hex(c1, 4) * (1 - t) + hex(c2, 4) * t + 0.5)
	local b = math.floor(hex(c1, 6) * (1 - t) + hex(c2, 6) * t + 0.5)
	return string.format("#%02x%02x%02x", r, g, b)
end

-- Build a single action button with rubato hover animation
local function make_button(icon, label, shortcut_key, action)
	local cfg = M._state.cfg
	local hover_bg = cfg.hover_bg or (cfg.icon_color:sub(1, 7) .. "30")

	local icon_widget = wibox.widget({
		markup = string.format('<span foreground="%s">%s</span>', cfg.icon_color, icon),
		font = cfg.icon_font,
		halign = "center",
		valign = "center",
		widget = wibox.widget.textbox,
	})

	local label_markup_normal = M.highlight_label(label, shortcut_key, cfg.icon_color, cfg.fg_color)
	local label_markup_hover = M.highlight_label(label, shortcut_key, cfg.icon_hover, "#ffffff")
	local label_widget = wibox.widget({
		markup = label_markup_normal,
		font = cfg.font,
		halign = "center",
		widget = wibox.widget.textbox,
	})

	-- Margin container for animated "zoom" effect (shrink margins = grow content)
	local icon_margin = wibox.container.margin(icon_widget, dpi(8), dpi(8), dpi(8), dpi(8))

	local btn = wibox.widget({
		{
			{
				icon_margin,
				label_widget,
				spacing = dpi(8),
				layout = wibox.layout.fixed.vertical,
			},
			margins = dpi(16),
			widget = wibox.container.margin,
		},
		forced_width = dpi(155),
		forced_height = dpi(180),
		bg = "transparent",
		border_width = dpi(1),
		border_color = "transparent",
		shape = function(cr, w, h) gears.shape.rounded_rect(cr, w, h, dpi(14)) end,
		widget = wibox.container.background,
	})

	-- Rubato timed animation: 0 = idle, 1 = fully hovered
	local hover_anim = rubato.timed({
		pos = 0,
		duration = cfg.anim_duration,
		intro = cfg.anim_intro,
		outro = cfg.anim_outro,
		easing = rubato.easing.quadratic,
		subscribed = function(t)
			-- Clamp t to 0..1
			t = math.max(0, math.min(1, t))

			-- Icon zoom: reduce margins from dpi(8) → dpi(0)
			local m = math.floor(dpi(8) * (1 - t) + 0.5)
			icon_margin.left = m
			icon_margin.right = m
			icon_margin.top = m
			icon_margin.bottom = m

			-- Background + border fade
			if t > 0.01 then
				local alpha_bg = string.format("%02x", math.floor(t * 0x30 + 0.5))
				local alpha_border = string.format("%02x", math.floor(t * 0.4 * 255 + 0.5))
				btn.bg = hover_bg:sub(1, 7) .. alpha_bg
				btn.border_color = cfg.icon_color:sub(1, 7) .. alpha_border
			else
				btn.bg = "transparent"
				btn.border_color = "transparent"
			end

			-- Icon color interpolation
			local icon_color = M.lerp_color(cfg.icon_color:sub(1, 7), cfg.icon_hover:sub(1, 7), t)
			icon_widget.markup = string.format('<span foreground="%s">%s</span>', icon_color, icon)

			-- Label swap at halfway
			if t > 0.5 then
				label_widget.markup = label_markup_hover
			else
				label_widget.markup = label_markup_normal
			end
		end,
	})

	btn:connect_signal("mouse::enter", function()
		hover_anim.target = 1
		local w = _G.mouse.current_wibox
		if w then w.cursor = "hand1" end
	end)
	btn:connect_signal("mouse::leave", function()
		hover_anim.target = 0
		local w = _G.mouse.current_wibox
		if w then w.cursor = "left_ptr" end
	end)

	btn:buttons(gears.table.join(
		awful.button({}, 1, function()
			awesome.emit_signal("exit_screen::close")
			gears.timer.start_new(0.1, function()
				action()
				return false
			end)
		end)
	))

	return btn
end

local function close()
	if M._state.exit_wb then M._state.exit_wb.visible = false end
	if M._state.grabber then
		M._state.grabber:stop()
		M._state.grabber = nil
	end
end

local function open()
	if not M._state.exit_wb then return end
	local cfg = M._state.cfg

	-- Update geometry to focused screen
	local s = awful.screen.focused()
	M._state.exit_wb.x = s.geometry.x
	M._state.exit_wb.y = s.geometry.y
	M._state.exit_wb.width = s.geometry.width
	M._state.exit_wb.height = s.geometry.height
	M._state.exit_wb.screen = s
	M._state.exit_wb.visible = true

	-- Actions table
	local actions = {
		p = function() awful.spawn.with_shell("systemctl poweroff") end,
		r = function() awful.spawn.with_shell("systemctl reboot") end,
		s = function() awful.spawn.with_shell("systemctl suspend") end,
		f = function() awesome.restart() end,
		e = function() awesome.quit() end,
		l = function() awesome.lock() end,
	}

	M._state.grabber = awful.keygrabber({
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
	if M._state.exit_wb and M._state.exit_wb.visible then
		awesome.emit_signal("exit_screen::close")
	else
		awesome.emit_signal("exit_screen::open")
	end
end

--- Initialize the exit screen module.
-- @tparam[opt] table opts Configuration overrides
function M.init(opts)
	if M._state.initialized then return end
	M._state.initialized = true

	M._state.cfg = M.resolve_config(opts)
	local cfg = M._state.cfg

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
	local lock = make_button("\xef\x80\xa3", "Lock", "L",
		function() awesome.lock() end)

	local buttons_row = wibox.widget({
		poweroff, reboot, suspend, refresh, exit, lock,
		spacing = dpi(16),
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
	M._state.exit_wb = wibox({
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
	M._state.exit_wb:buttons(gears.table.join(
		awful.button({}, 2, function() awesome.emit_signal("exit_screen::close") end),
		awful.button({}, 3, function() awesome.emit_signal("exit_screen::close") end)
	))

	-- Signals
	awesome.connect_signal("exit_screen::open", open)
	awesome.connect_signal("exit_screen::close", close)
	awesome.connect_signal("exit_screen::toggle", toggle)
end

return M
