-- somewmrc.lua - Default configuration for somewm (AwesomeWM on Wayland)
--
-- Copy this file to ~/.config/somewm/rc.lua and customize it.
-- Press Mod4+s to see all keybindings.
--
-- Coming from AwesomeWM on X11? See docs/reference/deviations for the Wayland
-- differences (no xprop/xdotool/picom, xkb is compositor-side, etc.). The
-- public Lua API is preserved; X11-specific tooling is what changes.

local gears = require("gears")
local awful = require("awful")
require("awful.autofocus")
local wibox = require("wibox")
local beautiful = require("beautiful")
local dpi = beautiful.xresources.apply_dpi
local naughty = require("naughty")
local ruled = require("ruled")
local menubar = require("menubar")
local hotkeys_popup = require("awful.hotkeys_popup")

-- Error handling
naughty.connect_signal("request::display_error", function(message, startup)
    naughty.notification {
        urgency = "critical",
        title   = "Oops, an error happened"..(startup and " during startup!" or "!"),
        message = message
    }
end)

-- Show notification if we fell back due to X11-specific patterns in user config
if awesome.x11_fallback_info then
    gears.timer.delayed_call(function()
        local info = awesome.x11_fallback_info
        local msg = string.format(
            "Your config was skipped because it contains X11-specific code that " ..
            "won't work on Wayland.\n\n" ..
            "File: %s:%d\n" ..
            "Pattern: %s\n" ..
            "Code: %s\n\n" ..
            "Suggestion: %s\n\n" ..
            "Edit your rc.lua to remove X11 dependencies, then restart somewm.",
            info.config_path or "unknown",
            info.line_number or 0,
            info.pattern or "unknown",
            info.line_content or "",
            info.suggestion or "See somewm migration guide"
        )
        naughty.notification {
            urgency = "critical",
            title   = "Config contains X11 patterns - using fallback",
            message = msg,
            timeout = 0
        }
    end)
end

-- Theme: persisted in ~/.config/somewm/theme, defaults to gruvbox
local theme_file = (os.getenv("XDG_CONFIG_HOME") or os.getenv("HOME") .. "/.config") .. "/somewm/theme"
local theme_name = "gruvbox"
do
    local f = io.open(theme_file, "r")
    if f then
        local name = f:read("*l")
        if name and name ~= "" then theme_name = name end
        f:close()
    end
end

-- Simple theme switcher that writes the selected theme to a file and restarts somewm.
local function switch_theme(name)
    local dir = (os.getenv("XDG_CONFIG_HOME") or os.getenv("HOME") .. "/.config") .. "/somewm"
    os.execute("mkdir -p " .. dir)
    local f = io.open(theme_file, "w")
    if f then
        f:write(name .. "\n")
        f:close()
    end
    awesome.restart()
end

beautiful.init(gears.filesystem.get_themes_dir() .. theme_name .. "/theme.lua")

-- Setup the menu/launcher with an "s" instead of AwesomeWM's "a".
-- Same blocky style as beautiful.theme_assets.gen_awesome_name (the "s" letter
-- is letter 3 in the "awesome" wordmark): a square filled with `fg`, with two
-- thin horizontal cuts in `bg` at y=1/3 (right two-thirds) and y=2/3 (left
-- two-thirds).
do
    local cairo = require("lgi").cairo
    local size = beautiful.menu_height
    local fg   = beautiful.wallpaper_logo_color or beautiful.fg_focus
    local bg   = beautiful.wibar_bg or beautiful.bg_normal

    local img = cairo.ImageSurface(cairo.Format.ARGB32, size, size)
    local cr  = cairo.Context(img)
    cr:set_line_width(size / 18)

    cr:set_source(gears.color(fg))
    cr:rectangle(0, 0, size, size)
    cr:fill()

    if bg then
        cr:set_source(gears.color(bg))
    else
        cr:set_operator(cairo.Operator.CLEAR)
    end
    cr:move_to(size/3, size/3); cr:rel_line_to(size*2/3, 0); cr:stroke()
    cr:move_to(0, size*2/3);    cr:rel_line_to(size*2/3, 0); cr:stroke()
    cr:set_operator(cairo.Operator.OVER)

    beautiful.awesome_icon = img
end

-- Lockscreen (must be after beautiful.init)
require("lockscreen").init()

-- Defaults
-- Change these to your preferred terminal and editor, or use xdg-terminal and xdg-editor if available.
local terminal = "foot"
local editor = os.getenv("EDITOR") or "nano"
local editor_cmd = terminal .. " -e " .. editor
local modkey = "Mod4"

-- ============================================================
-- User customization (uncomment to enable)
-- ============================================================

-- Keyboard layout / xkb options (somewm-side, no setxkbmap needed).
-- awful.input.xkb_layout  = "us"
-- awful.input.xkb_variant = ""
-- awful.input.xkb_options = "caps:escape"

-- Pointer / touchpad (libinput-backed; see awful.input for the full list).
-- awful.input.tap_to_click      = 1
-- awful.input.natural_scrolling = 1
-- awful.input.pointer_speed     = 0.5

-- Per-monitor fractional scaling.
-- output.connect_signal("added", function(o)
--     if o.name == "HDMI-A-1" then o.scale = 1.5 end
-- end)

-- Autostart (idempotent across reloads). somewm provides notifications and
-- wallpapers natively, so don't run mako/swaybg/dunst.
-- awful.spawn.once("nm-applet")        -- network tray
-- awful.spawn.once("blueman-applet")   -- bluetooth tray
-- awful.spawn.once("udiskie --tray")   -- auto-mount removable drives

-- Auto-lock after N seconds of idle.
-- awesome.set_idle_timeout("auto-lock", 600, function() awesome.lock() end)

-- Inhibit idle while presenting / watching a long video. Combines with
-- protocol-level inhibitors (mpv, browsers); see awesome.idle_inhibited
-- for the OR'd state.
-- awful.keyboard.append_global_keybindings({ awful.key {
--     modifiers = { modkey, "Shift" }, key = "i",
--     on_press = function() awesome.idle_inhibit = not awesome.idle_inhibit end,
--     description = "toggle idle inhibit", group = "awesome",
-- } })

-- Animated layout transitions (somewm-specific). Tiled clients fly smoothly
-- between positions on layout changes, mwfact tweaks, client spawn/close, etc.
-- local layout_anim = require("somewm.layout_animation")
-- layout_anim.duration = 0.15
-- layout_anim.easing   = "ease-out-cubic"

-- Custom IPC commands. After reload, callable as:
--   somewm-client run focused-tag
-- awful.ipc.register("focused-tag", function()
--     local t = awful.screen.focused().selected_tag
--     return t and t.name or ""
-- end)

-- Menu
local theme_menu = {
    { "gruvbox",    function() switch_theme("gruvbox") end },
    { "catppuccin", function() switch_theme("catppuccin") end },
    { "nord",       function() switch_theme("nord") end },
}

local menu_items = {
   { "hotkeys", function() hotkeys_popup.show_help(nil, awful.screen.focused()) end },
   { "terminal", function() awful.spawn(terminal) end },
   { "theme", theme_menu },
   { "edit config", editor_cmd .. " " .. awesome.conffile },
   { "restart", awesome.restart },
   { "lock", function() awesome.lock() end },
   { "quit", function() awesome.quit() end },
}

mymainmenu = awful.menu({ items = { { "somewm", menu_items, beautiful.awesome_icon },
                                    { "open terminal", terminal }
                                  }
                        })

mylauncher = awful.widget.launcher({ image = beautiful.awesome_icon,
                                     menu = mymainmenu })

menubar.utils.terminal = terminal

-- Layouts
-- Signal-driven layout registration. Fires once at startup; config code appends
-- to the layouts list so multiple chunks (defaults + user additions) can compose.
tag.connect_signal("request::default_layouts", function()
    awful.layout.append_default_layouts({
        awful.layout.suit.tile,
        awful.layout.suit.tile.left,
        awful.layout.suit.tile.bottom,
        awful.layout.suit.tile.top,
        awful.layout.suit.carousel,
        awful.layout.suit.fair,
        awful.layout.suit.fair.horizontal,
        awful.layout.suit.max,
        awful.layout.suit.corner.nw,
        awful.layout.suit.floating,
        awful.layout.suit.spiral,
        awful.layout.suit.spiral.dwindle,
        awful.layout.suit.max.fullscreen,
        awful.layout.suit.magnifier,
    })
end)

-- Wallpaper
screen.connect_signal("request::wallpaper", function(s)
    local colors = beautiful.wallpaper_colors
    if colors then
        local dpi = beautiful.xresources.apply_dpi
        local logo_size = dpi(200)
        local logo_color = beautiful.wallpaper_logo_color
        local logo_path = gears.filesystem.get_themes_dir() .. "../icons/somewm-logo.svg"

        -- Recolor logo to match theme
        local logo_widget = nil
        if logo_color then
            local logo_image = gears.color.recolor_image(logo_path, logo_color)
            logo_widget = {
                {
                    image         = logo_image,
                    forced_height = logo_size,
                    forced_width  = logo_size,
                    widget        = wibox.widget.imagebox,
                },
                valign = "center",
                halign = "center",
                widget = wibox.container.place,
            }
        end

        awful.wallpaper {
            screen = s,
            bg     = {
                type  = "linear",
                from  = { 0, 0 },
                to    = { s.geometry.width, s.geometry.height },
                stops = { { 0, colors[1] }, { 1, colors[2] } },
            },
            widget = logo_widget,
        }
    elseif beautiful.wallpaper then
        awful.wallpaper {
            screen = s,
            widget = {
                {
                    image     = beautiful.wallpaper,
                    upscale   = true,
                    downscale = true,
                    widget    = wibox.widget.imagebox,
                },
                valign = "center",
                halign = "center",
                tiled  = false,
                widget = wibox.container.tile,
            }
        }
    else
        awful.wallpaper { screen = s, bg = beautiful.bg_normal or "#222222" }
    end
end)

-- Tag persistence across monitor hotplug
-- The save handler lives in awful.permissions.tag_screen and stores tag
-- metadata into awful.permissions.saved_tags keyed by connector name.
-- To disable or replace it:
--   tag.disconnect_signal("request::screen", awful.permissions.tag_screen)

-- Wibar

local mytextclock = wibox.widget {
    {
        {
            format = "%a %b %d  %H:%M",
            widget = wibox.widget.textclock,
        },
        left   = dpi(8),
        right  = dpi(8),
        widget = wibox.container.margin,
    },
    bg     = beautiful.clock_bg or beautiful.bg_focus,
    shape  = function(cr, w, h) gears.shape.rounded_rect(cr, w, h, dpi(4)) end,
    widget = wibox.container.background,
}

-- Fires once per screen at startup AND on monitor hotplug. Restore saved tags
-- if this connector was previously seen; otherwise create the default set.
screen.connect_signal("request::desktop_decoration", function(s)
    -- Restore saved tags if this output was previously removed
    local output_name = s.output and s.output.name
    local restore = output_name and awful.permissions.saved_tags[output_name]
    if restore then
        awful.permissions.saved_tags[output_name] = nil
        local client_tags = {}
        for _, td in ipairs(restore) do
            local t = awful.tag.add(td.name, {
                screen = s,
                layout = td.layout,
                master_width_factor = td.master_width_factor,
                master_count = td.master_count,
                gap = td.gap,
                selected = td.selected,
            })
            for _, c in ipairs(td.clients) do
                if c.valid then
                    if not client_tags[c] then
                        client_tags[c] = {}
                    end
                    table.insert(client_tags[c], t)
                end
            end
        end
        for c, tags in pairs(client_tags) do
            c:move_to_screen(s)
            c:tags(tags)
        end
    else
        awful.tag({ "dev", "web", "chat", "files", "media" }, s, awful.layout.layouts[1])
    end

    s.mypromptbox = awful.widget.prompt()

    s.mylayoutbox = awful.widget.layoutbox {
        screen  = s,
        buttons = {
            awful.button({ }, 1, function () awful.layout.inc( 1) end),
            awful.button({ }, 3, function () awful.layout.inc(-1) end),
            awful.button({ }, 4, function () awful.layout.inc(-1) end),
            awful.button({ }, 5, function () awful.layout.inc( 1) end),
        }
    }

    s.mytaglist = awful.widget.taglist {
        screen  = s,
        filter  = awful.widget.taglist.filter.all,
        buttons = {
            awful.button({ }, 1, function(t) t:view_only() end),
            awful.button({ modkey }, 1, function(t)
                                            if client.focus then
                                                client.focus:move_to_tag(t)
                                            end
                                        end),
            awful.button({ }, 3, awful.tag.viewtoggle),
            awful.button({ modkey }, 3, function(t)
                                            if client.focus then
                                                client.focus:toggle_tag(t)
                                            end
                                        end),
            awful.button({ }, 4, function(t) awful.tag.viewprev(t.screen) end),
            awful.button({ }, 5, function(t) awful.tag.viewnext(t.screen) end),
        }
    }

    s.mytasklist = awful.widget.tasklist {
        screen  = s,
        filter  = awful.widget.tasklist.filter.currenttags,
        buttons = {
            awful.button({ }, 1, function (c)
                c:activate { context = "tasklist", action = "toggle_minimization" }
            end),
            awful.button({ }, 3, function() awful.menu.client_list { theme = { width = 250 } } end),
            awful.button({ }, 4, function() awful.client.focus.byidx(-1) end),
            awful.button({ }, 5, function() awful.client.focus.byidx( 1) end),
        },
        layout = {
            spacing = dpi(4),
            layout  = wibox.layout.fixed.horizontal,
        },
        widget_template = {
            {
                {
                    { id = "icon_role", widget = awful.widget.clienticon },
                    id     = "icon_margin_role",
                    left   = dpi(6),
                    right  = dpi(2),
                    top    = dpi(4),
                    bottom = dpi(4),
                    widget = wibox.container.margin,
                },
                {
                    { id = "text_role", widget = wibox.widget.textbox },
                    id     = "text_margin_role",
                    right  = dpi(6),
                    widget = wibox.container.margin,
                },
                layout = wibox.layout.fixed.horizontal,
            },
            id     = "background_role",
            widget = wibox.container.background,
        },
    }

    s.mywibox = awful.wibar {
        position  = "top",
        screen    = s,
        widget    = {
            layout = wibox.layout.stack,
            {
                layout = wibox.layout.align.horizontal,
                {
                    layout = wibox.layout.fixed.horizontal,
                    mylauncher,
                    s.mytaglist,
                    s.mypromptbox,
                    s.mytasklist,
                },
                { widget = wibox.container.background },
                {
                    layout = wibox.layout.fixed.horizontal,
                    wibox.widget.systray(),
                    s.mylayoutbox,
                },
            },
            {
                mytextclock,
                halign = "center",
                widget = wibox.container.place,
            },
        }
    }
end)

-- Mouse bindings
awful.mouse.append_global_mousebindings({
    awful.button({ }, 3, function () mymainmenu:toggle() end),
    awful.button({ }, 4, awful.tag.viewprev),
    awful.button({ }, 5, awful.tag.viewnext),
})

-- Key bindings

-- somewm
awful.keyboard.append_global_keybindings({
    awful.key {
        modifiers   = { modkey },
        key         = "s",
        on_press    = hotkeys_popup.show_help,
        description = "show help",
        group       = "somewm",
    },
    awful.key {
        modifiers   = { modkey },
        key         = "w",
        on_press    = function() mymainmenu:show() end,
        description = "show main menu",
        group       = "somewm",
    },
    awful.key {
        modifiers   = { modkey, "Control" },
        key         = "r",
        on_press    = awesome.restart,
        description = "reload somewm",
        group       = "somewm",
    },
    awful.key {
        modifiers   = { modkey, "Shift" },
        key         = "q",
        on_press    = awesome.quit,
        description = "quit somewm",
        group       = "somewm",
    },
    awful.key {
        modifiers   = { modkey, "Shift" },
        key         = "Escape",
        on_press    = function() awesome.lock() end,
        description = "lock screen",
        group       = "somewm",
    },
    awful.key {
        modifiers   = { modkey },
        key         = "x",
        on_press    = function()
            awful.prompt.run {
                prompt       = "Run Lua code: ",
                textbox      = awful.screen.focused().mypromptbox.widget,
                exe_callback = awful.util.eval,
                history_path = awful.util.get_cache_dir() .. "/history_eval",
            }
        end,
        description = "lua execute prompt",
        group       = "somewm",
    },
    awful.key {
        modifiers   = { modkey, "Shift" },
        key         = "d",
        on_press    = function()
            naughty.suspended = not naughty.suspended
            naughty.notification {
                title          = "Notifications",
                text           = naughty.suspended and "Do Not Disturb" or "Resumed",
                timeout        = 2,
                ignore_suspend = true,
            }
        end,
        description = "toggle do-not-disturb",
        group       = "somewm",
    },
})

-- launcher
awful.keyboard.append_global_keybindings({
    awful.key {
        modifiers   = { modkey },
        key         = "Return",
        on_press    = function() awful.spawn(terminal) end,
        description = "open a terminal",
        group       = "launcher",
    },
    awful.key {
        modifiers   = { modkey },
        key         = "r",
        on_press    = function() awful.screen.focused().mypromptbox:run() end,
        description = "run prompt",
        group       = "launcher",
    },
    awful.key {
        modifiers   = { modkey },
        key         = "p",
        on_press    = function() menubar.show() end,
        description = "show the menubar",
        group       = "launcher",
    },
})

-- tag
awful.keyboard.append_global_keybindings({
    awful.key {
        modifiers   = { modkey },
        key         = "Left",
        on_press    = awful.tag.viewprev,
        description = "view previous",
        group       = "tag",
    },
    awful.key {
        modifiers   = { modkey },
        key         = "Right",
        on_press    = awful.tag.viewnext,
        description = "view next",
        group       = "tag",
    },
    awful.key {
        modifiers   = { modkey },
        key         = "Escape",
        on_press    = awful.tag.history.restore,
        description = "go back",
        group       = "tag",
    },
    awful.key {
        modifiers   = { modkey, "Shift" },
        key         = "r",
        on_press    = function()
            local s = awful.screen.focused()
            local t = s.selected_tag
            if not t then return end
            awful.prompt.run {
                prompt       = "Rename tag: ",
                text         = t.name,
                textbox      = s.mypromptbox.widget,
                exe_callback = function(new_name)
                    if new_name and new_name ~= "" then t.name = new_name end
                end,
            }
        end,
        description = "rename current tag",
        group       = "tag",
    },
})

-- client
awful.keyboard.append_global_keybindings({
    awful.key {
        modifiers   = { modkey },
        key         = "j",
        on_press    = function() awful.client.focus.byidx(1) end,
        description = "focus next by index",
        group       = "client",
    },
    awful.key {
        modifiers   = { modkey },
        key         = "k",
        on_press    = function() awful.client.focus.byidx(-1) end,
        description = "focus previous by index",
        group       = "client",
    },
    awful.key {
        modifiers   = { modkey },
        key         = "Tab",
        on_press    = function()
            awful.client.focus.history.previous()
            if client.focus then
                client.focus:raise()
            end
        end,
        description = "go back",
        group       = "client",
    },
    awful.key {
        modifiers   = { modkey },
        key         = "u",
        on_press    = awful.client.urgent.jumpto,
        description = "jump to urgent client",
        group       = "client",
    },
    awful.key {
        modifiers   = { modkey, "Shift" },
        key         = "j",
        on_press    = function() awful.client.swap.byidx(1) end,
        description = "swap with next client by index",
        group       = "client",
    },
    awful.key {
        modifiers   = { modkey, "Shift" },
        key         = "k",
        on_press    = function() awful.client.swap.byidx(-1) end,
        description = "swap with previous client by index",
        group       = "client",
    },
    awful.key {
        modifiers   = { modkey, "Control" },
        key         = "n",
        on_press    = function()
            local c = awful.client.restore()
            if c then
                c:activate { raise = true, context = "key.unminimize" }
            end
        end,
        description = "restore minimized",
        group       = "client",
    },
})

-- screen
awful.keyboard.append_global_keybindings({
    awful.key {
        modifiers   = { modkey, "Control" },
        key         = "j",
        on_press    = function() awful.screen.focus_relative(1) end,
        description = "focus the next screen",
        group       = "screen",
    },
    awful.key {
        modifiers   = { modkey, "Control" },
        key         = "k",
        on_press    = function() awful.screen.focus_relative(-1) end,
        description = "focus the previous screen",
        group       = "screen",
    },
})

-- audio (requires wpctl from wireplumber)
awful.keyboard.append_global_keybindings({
    awful.key {
        modifiers   = {},
        key         = "XF86AudioRaiseVolume",
        on_press    = function() awful.spawn("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+") end,
        description = "raise volume",
        group       = "audio",
    },
    awful.key {
        modifiers   = {},
        key         = "XF86AudioLowerVolume",
        on_press    = function() awful.spawn("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-") end,
        description = "lower volume",
        group       = "audio",
    },
    awful.key {
        modifiers   = {},
        key         = "XF86AudioMute",
        on_press    = function() awful.spawn("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle") end,
        description = "mute output",
        group       = "audio",
    },
    awful.key {
        modifiers   = {},
        key         = "XF86AudioMicMute",
        on_press    = function() awful.spawn("wpctl set-mute @DEFAULT_SOURCE@ toggle") end,
        description = "mute microphone",
        group       = "audio",
    },
})

-- brightness (requires brightnessctl)
awful.keyboard.append_global_keybindings({
    awful.key {
        modifiers   = {},
        key         = "XF86MonBrightnessUp",
        on_press    = function() awful.spawn("brightnessctl set 5%+") end,
        description = "raise brightness",
        group       = "brightness",
    },
    awful.key {
        modifiers   = {},
        key         = "XF86MonBrightnessDown",
        on_press    = function() awful.spawn("brightnessctl set 5%-") end,
        description = "lower brightness",
        group       = "brightness",
    },
})

-- screenshot (requires grim, slurp)
awful.keyboard.append_global_keybindings({
    awful.key {
        modifiers   = {},
        key         = "Print",
        on_press    = function()
            awful.spawn.with_shell(
                "mkdir -p ~/Pictures && grim ~/Pictures/screenshot-$(date +%Y%m%d-%H%M%S).png"
            )
        end,
        description = "screenshot full output",
        group       = "screenshot",
    },
    awful.key {
        modifiers   = { "Shift" },
        key         = "Print",
        on_press    = function()
            awful.spawn.with_shell(
                "mkdir -p ~/Pictures && slurp | grim -g - ~/Pictures/screenshot-$(date +%Y%m%d-%H%M%S).png"
            )
        end,
        description = "screenshot region",
        group       = "screenshot",
    },
})

-- layout
awful.keyboard.append_global_keybindings({
    awful.key {
        modifiers   = { modkey },
        key         = "l",
        on_press    = function() awful.tag.incmwfact(0.05) end,
        description = "increase master width factor",
        group       = "layout",
    },
    awful.key {
        modifiers   = { modkey },
        key         = "h",
        on_press    = function() awful.tag.incmwfact(-0.05) end,
        description = "decrease master width factor",
        group       = "layout",
    },
    awful.key {
        modifiers   = { modkey, "Shift" },
        key         = "h",
        on_press    = function() awful.tag.incnmaster(1, nil, true) end,
        description = "increase the number of master clients",
        group       = "layout",
    },
    awful.key {
        modifiers   = { modkey, "Shift" },
        key         = "l",
        on_press    = function() awful.tag.incnmaster(-1, nil, true) end,
        description = "decrease the number of master clients",
        group       = "layout",
    },
    awful.key {
        modifiers   = { modkey, "Control" },
        key         = "h",
        on_press    = function() awful.tag.incncol(1, nil, true) end,
        description = "increase the number of columns",
        group       = "layout",
    },
    awful.key {
        modifiers   = { modkey, "Control" },
        key         = "l",
        on_press    = function() awful.tag.incncol(-1, nil, true) end,
        description = "decrease the number of columns",
        group       = "layout",
    },
    awful.key {
        modifiers   = { modkey },
        key         = "space",
        on_press    = function() awful.layout.inc(1) end,
        description = "select next",
        group       = "layout",
    },
    awful.key {
        modifiers   = { modkey, "Shift" },
        key         = "space",
        on_press    = function() awful.layout.inc(-1) end,
        description = "select previous",
        group       = "layout",
    },
})

-- tag (numrow)
--
-- These bindings work as four Mod variants:
--   Mod+N            view only this tag
--   Mod+Ctrl+N       toggle viewing this tag (multi-tag view)
--   Mod+Shift+N      move focused client to this tag
--   Mod+Ctrl+Shift+N toggle focused client on this tag (one client, many tags)
awful.keyboard.append_global_keybindings({
    awful.key {
        modifiers   = { modkey },
        keygroup    = "numrow",
        description = "only view tag",
        group       = "tag",
        on_press    = function(index)
            local screen = awful.screen.focused()
            local tag = screen.tags[index]
            if tag then
                tag:view_only()
            end
        end,
    },
    awful.key {
        modifiers   = { modkey, "Control" },
        keygroup    = "numrow",
        description = "toggle tag",
        group       = "tag",
        on_press    = function(index)
            local screen = awful.screen.focused()
            local tag = screen.tags[index]
            if tag then
                awful.tag.viewtoggle(tag)
            end
        end,
    },
    awful.key {
        modifiers   = { modkey, "Shift" },
        keygroup    = "numrow",
        description = "move focused client to tag",
        group       = "tag",
        on_press    = function(index)
            if client.focus then
                local tag = client.focus.screen.tags[index]
                if tag then
                    client.focus:move_to_tag(tag)
                end
            end
        end,
    },
    awful.key {
        modifiers   = { modkey, "Control", "Shift" },
        keygroup    = "numrow",
        description = "toggle focused client on tag",
        group       = "tag",
        on_press    = function(index)
            if client.focus then
                local tag = client.focus.screen.tags[index]
                if tag then
                    client.focus:toggle_tag(tag)
                end
            end
        end,
    },
})

-- layout (numpad)
awful.keyboard.append_global_keybindings({
    awful.key {
        modifiers   = { modkey },
        keygroup    = "numpad",
        description = "select layout directly",
        group       = "layout",
        on_press    = function(index)
            local t = awful.screen.focused().selected_tag
            if t then
                t.layout = t.layouts[index] or t.layout
            end
        end,
    },
})

-- Client mouse bindings registered via signal so user code can append to the
-- defaults. The same pattern repeats below for keybindings and rules.
client.connect_signal("request::default_mousebindings", function()
    awful.mouse.append_client_mousebindings({
        awful.button({ }, 1, function(c)
            c:activate { context = "mouse_click" }
        end),
        awful.button({ modkey }, 1, function(c)
            c:activate { context = "mouse_click", action = "mouse_move" }
        end),
        awful.button({ modkey }, 3, function(c)
            c:activate { context = "mouse_click", action = "mouse_resize" }
        end),
    })
end)

client.connect_signal("request::default_keybindings", function()
    awful.keyboard.append_client_keybindings({
        awful.key {
            modifiers   = { modkey },
            key         = "f",
            on_press    = function(c)
                c.fullscreen = not c.fullscreen
                c:raise()
            end,
            description = "toggle fullscreen",
            group       = "client",
        },
        awful.key {
            modifiers   = { modkey, "Shift" },
            key         = "c",
            on_press    = function(c) c:kill() end,
            description = "close",
            group       = "client",
        },
        awful.key {
            modifiers   = { modkey, "Control" },
            key         = "space",
            on_press    = function(c) c.floating = not c.floating end,
            description = "toggle floating",
            group       = "client",
        },
        awful.key {
            modifiers   = { modkey, "Control" },
            key         = "Return",
            on_press    = function(c) c:swap(awful.client.visible(c.screen)[1]) end,
            description = "move to master",
            group       = "client",
        },
        awful.key {
            modifiers   = { modkey },
            key         = "o",
            on_press    = function(c) c:move_to_screen() end,
            description = "move to screen",
            group       = "client",
        },
        awful.key {
            modifiers   = { modkey },
            key         = "t",
            on_press    = function(c) c.ontop = not c.ontop end,
            description = "toggle keep on top",
            group       = "client",
        },
        awful.key {
            modifiers   = { modkey },
            key         = ",",
            on_press    = function(c) c.sticky = not c.sticky end,
            description = "toggle sticky (show on all tags)",
            group       = "client",
        },
        awful.key {
            modifiers   = { modkey },
            key         = "n",
            on_press    = function(c) c.minimized = true end,
            description = "minimize",
            group       = "client",
        },
        awful.key {
            modifiers   = { modkey },
            key         = "m",
            on_press    = function(c)
                c.maximized = not c.maximized
                c:raise()
            end,
            description = "(un)maximize",
            group       = "client",
        },
        awful.key {
            modifiers   = { modkey, "Control" },
            key         = "m",
            on_press    = function(c)
                c.maximized_vertical = not c.maximized_vertical
                c:raise()
            end,
            description = "(un)maximize vertically",
            group       = "client",
        },
        awful.key {
            modifiers   = { modkey, "Shift" },
            key         = "m",
            on_press    = function(c)
                c.maximized_horizontal = not c.maximized_horizontal
                c:raise()
            end,
            description = "(un)maximize horizontally",
            group       = "client",
        },
    })
end)

-- Rules
-- Client rules are appended via signal. `rule`/`rule_any` matches client
-- properties; `properties` is the defaults table applied on match.
ruled.client.connect_signal("request::rules", function()
    -- All clients match this rule.
    ruled.client.append_rule {
        id         = "global",
        rule       = { },
        properties = {
            focus     = awful.client.focus.filter,
            raise     = true,
            screen    = awful.screen.preferred,
            placement = awful.placement.no_overlap+awful.placement.no_offscreen
        }
    }

    -- Floating clients
    ruled.client.append_rule {
        id       = "floating",
        rule_any = {
            instance = { "pinentry" },
            class    = { "Blueman-manager", "Gpick" },
            role     = { "pop-up" },
        },
        properties = { floating = true }
    }

    -- Titlebars on normal clients and dialogs
    ruled.client.append_rule {
        id         = "titlebars",
        rule_any   = { type = { "normal", "dialog" } },
        properties = { titlebars_enabled = true }
    }
end)

-- Titlebars
client.connect_signal("request::titlebars", function(c)
    local buttons = {
        awful.button({ }, 1, function()
            c:activate { context = "titlebar", action = "mouse_move"  }
        end),
        awful.button({ }, 3, function()
            c:activate { context = "titlebar", action = "mouse_resize"}
        end),
    }

    awful.titlebar(c).widget = {
        {
            awful.titlebar.widget.iconwidget(c),
            buttons = buttons,
            layout  = wibox.layout.fixed.horizontal
        },
        {
            {
                halign = "center",
                widget = awful.titlebar.widget.titlewidget(c)
            },
            buttons = buttons,
            layout  = wibox.layout.flex.horizontal
        },
        {
            awful.titlebar.widget.floatingbutton (c),
            awful.titlebar.widget.maximizedbutton(c),
            awful.titlebar.widget.closebutton    (c),
            layout = wibox.layout.fixed.horizontal()
        },
        layout = wibox.layout.align.horizontal
    }
end)

-- Notifications
-- Notification rules use the same append-via-signal pattern as client rules.
-- Match on app_name/title/urgency/category, set bg/fg/timeout/ignore/etc.
ruled.notification.connect_signal('request::rules', function()
    ruled.notification.append_rule {
        rule       = { },
        properties = {
            screen           = awful.screen.preferred,
            implicit_timeout = 5,
        }
    }

    -- Per-app routing example: mute one app, bump urgency for another.
    -- ruled.notification.append_rule {
    --     rule       = { app_name = "Spotify" },
    --     properties = { ignore = true },
    -- }
    -- ruled.notification.append_rule {
    --     rule       = { app_name = "Slack", title = "@you" },
    --     properties = { urgency = "critical" },
    -- }
end)

naughty.connect_signal("request::display", function(n)
    naughty.layout.box { notification = n }
end)

-- Sloppy focus (focus follows mouse)
client.connect_signal("mouse::enter", function(c)
    c:activate { context = "mouse_enter", raise = false }
end)
