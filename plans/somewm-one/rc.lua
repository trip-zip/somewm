-- awesome_mode: api-level=4:screen=on
-- If LuaRocks is installed, make sure that packages installed through it are
-- found (e.g. lgi). If LuaRocks is not installed, do nothing.
pcall(require, "luarocks.loader")

-- @DOC_REQUIRE_SECTION@
-- Standard awesome library
local gears = require("gears")
local awful = require("awful")
require("awful.autofocus")
-- Widget and layout library
local wibox = require("wibox")
-- Theme handling library
local beautiful = require("beautiful")
-- Notification library
local naughty = require("naughty")
-- Declarative object management
local ruled = require("ruled")
local menubar = require("menubar")
local hotkeys_popup = require("awful.hotkeys_popup")
local xresources = require("beautiful.xresources")
local dpi = xresources.apply_dpi
-- Enable hotkeys help widget for VIM and other apps
-- when client with a matching name is opened:
require("awful.hotkeys_popup.keys")
-- local treetileBindings = require("treetile.bindings")
local machi = require("layout-machi")

-- Fishlive component framework
-- Services must be loaded BEFORE any factory.create() call
require("fishlive.services")
local factory = require("fishlive.factory")

-- {{{ Error handling + log aggregation
local error_log_path = os.getenv("HOME") .. "/.local/log/somewm-errors.log"

local function log_error(title, message)
    local f = io.open(error_log_path, "a")
    if f then
        f:write(string.format("[%s] %s: %s\n", os.date("%Y-%m-%d %H:%M:%S"), title, message))
        f:close()
    end
end

naughty.connect_signal("request::display_error", function(message, startup)
    local title = "Oops, an error happened" .. (startup and " during startup!" or "!")
    log_error(title, message)
    naughty.notification {
        urgency = "critical",
        title   = title,
        message = message
    }
end)

-- Show notification if we fell back due to X11-specific patterns in user config
if awesome.x11_fallback_info then
    -- Defer notification until after startup (naughty needs event loop running)
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
            timeout = 0  -- Don't auto-dismiss
        }
    end)
end
-- }}}

-- {{{ Variable definitions
-- @DOC_LOAD_THEME@
-- Themes define colours, icons, font and wallpapers.
local themeName = "default"
beautiful.init(gears.filesystem.get_configuration_dir() .. "themes/" .. themeName .. "/theme.lua")

-- Initialize lockscreen (must be after beautiful.init)
pcall(function() require("lockscreen").init() end)

-- Client animations loaded at end of rc.lua (after all signals are connected)

-- @DOC_DEFAULT_APPLICATIONS@
-- This is used later as the default terminal and editor to run.
terminal = "ghostty"
editor = os.getenv("EDITOR") or "nvim"
editor_cmd = terminal .. " -e " .. editor

-- Default modkey.
-- Usually, Mod4 is the key with a logo between Control and Alt.
-- If you do not like this or do not have such a key,
-- I suggest you to remap Mod4 to another key using xmodmap or other tools.
-- However, you can use another modifier like Mod1, but it may interact with others.
modkey = "Mod4"
altkey = "Mod1"

-- {{{ Keyboard layout configuration
-- Set multi-layout keymap: us + cz(qwerty)
-- Toggle with Alt+Shift (grp:alt_shift_toggle)
awesome._set_keyboard_setting("xkb_layout", "us,cz")
awesome._set_keyboard_setting("xkb_variant", ",qwerty")
awesome._set_keyboard_setting("xkb_options", "grp:alt_shift_toggle")
-- Enable NumLock on startup
awesome._set_keyboard_setting("numlock", true)
-- }}}

-- {{{ Menu
-- @DOC_MENU@
-- Create a launcher widget and a main menu
myawesomemenu = {
   { "hotkeys", function() hotkeys_popup.show_help(nil, awful.screen.focused()) end },
   { "manual", terminal .. " -e man awesome" },
   { "edit config", editor_cmd .. " " .. awesome.conffile },
   { "cold restart", awesome.cold_restart },
   { "rebuild & restart", awesome.rebuild_restart },
   { "quit", function() awesome.quit() end },
}

mymainmenu = awful.menu({ items = { { "awesome", myawesomemenu, beautiful.awesome_icon },
                                    { "open terminal", terminal }
                                  }
                        })

mylauncher = awful.widget.launcher({ image = beautiful.awesome_icon,
                                     menu = mymainmenu })

-- Menubar configuration
menubar.utils.terminal = terminal -- Set the terminal for applications that require it
-- }}}

-- {{{ Tag layout
-- @DOC_LAYOUT@
-- Table of layouts to cover with awful.layout.inc, order matters.
tag.connect_signal("request::default_layouts", function()
    awful.layout.append_default_layouts({
        awful.layout.suit.floating,
        awful.layout.suit.tile,
        machi.default_layout,
        awful.layout.suit.carousel,          -- niri-style scrollable tiling (animated)
        awful.layout.suit.carousel.vertical, -- vertical variant
        awful.layout.suit.tile.left,
        awful.layout.suit.tile.bottom,
        awful.layout.suit.tile.top,
        awful.layout.suit.fair,
        awful.layout.suit.fair.horizontal,
        awful.layout.suit.spiral,
        awful.layout.suit.spiral.dwindle,
        awful.layout.suit.max,
        awful.layout.suit.max.fullscreen,
        awful.layout.suit.magnifier,
        awful.layout.suit.corner.nw,
    })
end)
-- }}}

-- {{{ Wallpaper
-- @DOC_WALLPAPER@
-- Wallpaper handled in request::desktop_decoration with tag-based switching
-- }}}

-- {{{ Output configuration (SomeWM-specific)
-- Configure physical monitors by connector name / EDID
-- The "added::connected" mechanism retroactively fires the handler for
-- outputs that existed before rc.lua loaded (same pattern as screen class).
if output then
    output.connect_signal("added", function(o)
        -- Dell G3223Q — force 4K@144Hz (EDID preferred mode is 60Hz)
        if o.name == "DP-3" or (o.make and o.make:match("Dell") and o.model and o.model:match("G3223Q")) then
            o.mode = { width = 3840, height = 2160, refresh = 143963 }
        end
        -- Laptop panel (eDP) - fractional scaling
        if o.name:match("^eDP") then
            o.scale = 1.5
        end
    end)
end
-- }}}

-- {{{ Wibar

-- Keyboard map indicator and switcher
mykeyboardlayout = awful.widget.keyboardlayout()

-- Create a textclock widget — bright time, dimmer date
local markup = require("gears.string").xml_escape and "" or nil -- just need lgi.markup below
mytextclock = wibox.widget.textclock(
    '<span foreground="#b0b0b0" font="Geist 10"> %a %d %b</span>' ..
    '<span foreground="#e2b55a" font="Geist SemiBold 11"> %H:%M </span>', 60
)

-- Calendar popup on clock click
local cal_popup = awful.widget.calendar_popup.month({
    start_sunday = false,
    long_weekdays = true,
    style_month = {
        bg_color     = "#181818f0",
        border_color = "#e2b55a",
        border_width = 1,
        padding      = dpi(10),
    },
    style_header = {
        fg_color     = "#e2b55a",
        font         = "Geist SemiBold 12",
    },
    style_weekday = {
        fg_color     = "#888888",
        font         = "Geist 10",
    },
    style_normal = {
        fg_color     = "#d4d4d4",
        font         = "Geist 10",
    },
    style_focus = {
        fg_color     = "#181818",
        bg_color     = "#e2b55a",
        font         = "Geist Bold 10",
        shape        = gears.shape.circle,
    },
})
-- Show calendar on click, on the screen where the mouse is
mytextclock:connect_signal("button::press", function(_, _, _, button)
    if button == 1 then
        cal_popup.screen = awful.screen.focused()
        cal_popup:call_calendar(0, "tr", awful.screen.focused())
        cal_popup.visible = not cal_popup.visible
    end
end)

-- ---------------------------------------------------------------------------
-- Volume widget (PipeWire/WirePlumber native via wpctl)
-- ---------------------------------------------------------------------------
local volume_widget = wibox.widget {
    {
        id     = "icon",
        text   = "\u{1F50A} ",
        widget = wibox.widget.textbox,
    },
    {
        id     = "text",
        text   = "-%",
        widget = wibox.widget.textbox,
    },
    layout = wibox.layout.fixed.horizontal,
}

local function volume_update()
    awful.spawn.easy_async("wpctl get-volume @DEFAULT_AUDIO_SINK@", function(out)
        local vol = out:match("Volume:%s+([%d%.]+)")
        local muted = out:match("%[MUTED%]")
        if vol then
            local pct = math.floor(tonumber(vol) * 100 + 0.5)
            local icon_w = volume_widget:get_children_by_id("icon")[1]
            local text_w = volume_widget:get_children_by_id("text")[1]
            if muted then
                icon_w.text = "\u{1F507} "
                text_w.markup = string.format('<span foreground="#888888">%d%%</span>', pct)
            elseif pct > 60 then
                icon_w.text = "\u{1F50A} "
                text_w.text = pct .. "%"
            elseif pct > 20 then
                icon_w.text = "\u{1F509} "
                text_w.text = pct .. "%"
            else
                icon_w.text = "\u{1F508} "
                text_w.text = pct .. "%"
            end
        end
    end)
end

-- Poll every 2 seconds
gears.timer { timeout = 2, autostart = true, call_now = true, callback = volume_update }

-- Scroll = volume up/down
volume_widget:buttons(gears.table.join(
    awful.button({}, 1, function()  -- left click → pavucontrol
        awful.spawn("pavucontrol")
    end),
    awful.button({}, 2, function()  -- middle click → helvum
        awful.spawn("helvum")
    end),
    awful.button({}, 3, function()  -- right click → mute toggle
        awful.spawn.easy_async("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle", volume_update)
    end),
    awful.button({}, 4, function()  -- scroll up → volume +5%
        awful.spawn.easy_async("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+", volume_update)
    end),
    awful.button({}, 5, function()  -- scroll down → volume -5%
        awful.spawn.easy_async("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-", volume_update)
    end)
))

-- @DOC_FOR_EACH_SCREEN@
-- {{{ Tag persistence across monitor hotplug
-- The save handler lives in awful.permissions.tag_screen and stores tag
-- metadata into awful.permissions.saved_tags keyed by connector name.
-- To disable or replace it:
--   tag.disconnect_signal("request::screen", awful.permissions.tag_screen)
-- }}}

screen.connect_signal("request::desktop_decoration", function(s)
    -- Restore saved tags if this output was previously removed (hotplug)
    local output_name = s.output and s.output.name
    local restore = output_name and awful.permissions.saved_tags
        and awful.permissions.saved_tags[output_name]
    if restore then
        awful.permissions.saved_tags[output_name] = nil
        -- Pass 1: recreate tags and build per-client tag lists
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
        -- Pass 2: move clients and assign full tag lists
        for c, tags in pairs(client_tags) do
            c:move_to_screen(s)
            c:tags(tags)
        end
    else
        -- Each screen has its own tag table.
        awful.tag({ "1", "2", "3", "4", "5", "6", "7", "8", "9" }, s, awful.layout.layouts[1])
    end

    -- Create a promptbox for each screen
    s.mypromptbox = awful.widget.prompt()

    -- Layout selector popup (click layoutbox to pick layout)
    local layout_popup = awful.popup {
        widget = awful.widget.layoutlist {
            screen = s,
            base_layout = wibox.layout.flex.vertical,
            style = {
                font            = "Geist 10",
                bg_normal       = "#181818",
                bg_selected     = "#e2b55a",
                fg_normal       = "#d4d4d4",
                fg_selected     = "#181818",
            },
        },
        bg           = "#181818f0",
        border_color = "#c49a3a",
        border_width = 1,
        placement    = function(d)
            awful.placement.under_mouse(d)
            awful.placement.no_offscreen(d)
        end,
        shape        = function(cr, w, h) gears.shape.rounded_rect(cr, w, h, dpi(4)) end,
        maximum_width  = dpi(200),
        maximum_height = dpi(500),
        visible      = false,
        ontop        = true,
    }
    -- Hide on mouse leave
    layout_popup:connect_signal("mouse::leave", function() layout_popup.visible = false end)

    -- Create layoutbox with popup on click
    s.mylayoutbox = awful.widget.layoutbox {
        screen  = s,
        buttons = {
            awful.button({ }, 1, function ()
                layout_popup.screen = awful.screen.focused()
                layout_popup.visible = not layout_popup.visible
            end),
            awful.button({ }, 4, function () awful.layout.inc(-1) end),
            awful.button({ }, 5, function () awful.layout.inc( 1) end),
        }
    }

    -- Create a taglist widget
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

    -- @TASKLIST_BUTTON@
    -- Create a tasklist widget
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
        }
    }

    -- @DOC_WIBAR@
    -- Create the wibox
    s.mywibox = awful.wibar {
        position = "top",
        screen   = s,
        -- @DOC_SETUP_WIDGETS@
        widget   = {
            layout = wibox.layout.align.horizontal,
            { -- Left widgets
                layout = wibox.layout.fixed.horizontal,
                mylauncher,
                s.mytaglist,
                s.mypromptbox,
            },
            s.mytasklist, -- Middle widget
            { -- Right widgets (fishlive components with separators)
                layout = wibox.layout.fixed.horizontal,
                factory.create("keyboard", s),
                require("fishlive.widget_helper").separator(),
                factory.create("updates", s),
                require("fishlive.widget_helper").separator(),
                factory.create("cpu", s),
                require("fishlive.widget_helper").separator(),
                factory.create("gpu", s),
                require("fishlive.widget_helper").separator(),
                factory.create("memory", s),
                require("fishlive.widget_helper").separator(),
                factory.create("disk", s),
                require("fishlive.widget_helper").separator(),
                factory.create("network", s),
                require("fishlive.widget_helper").separator(),
                factory.create("volume", s),
                require("fishlive.widget_helper").separator(),
                wibox.widget {
                    wibox.widget.systray(),
                    left = 0, right = 0,
                    widget = wibox.container.margin,
                },
                factory.create("clock", s),
                factory.create("layoutbox", s),
            },
        }
    }

    -- =========================================================================
    -- Tag-based Wallpaper System (awful.wallpaper API + preload cache)
    -- =========================================================================
    local wppath = gears.filesystem.get_configuration_dir()
        .. "themes/" .. themeName .. "/wallpapers/"

    -- Wallpaper per tag: tag name (1-9) maps to wallpapers/N.jpg
    -- Default fallback for tags without a matching wallpaper file
    local default_wallpaper = "1.jpg"

    -- Track current wallpaper per screen to skip redundant updates
    s.current_wallpaper = nil
    s._wppath = wppath  -- exposed for tag_slide animation

    -- Set wallpaper using awful.wallpaper (new API, HiDPI-aware)
    local function set_wallpaper(scr, wallpaper_file)
        if scr.current_wallpaper == wallpaper_file then return end
        local path = wppath .. wallpaper_file
        if not gears.filesystem.file_readable(path) then
            path = wppath .. default_wallpaper
            wallpaper_file = default_wallpaper
        end
        awful.wallpaper {
            screen = scr,
            widget = {
                {
                    image     = path,
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
        scr.current_wallpaper = wallpaper_file
    end

    -- Initial wallpaper
    set_wallpaper(s, default_wallpaper)

    -- Pre-cache all wallpapers for tag_slide animation overlays
    if root.wallpaper_cache_preload then
        local paths = {}
        for i = 1, 9 do
            local wp = wppath .. i .. ".jpg"
            if gears.filesystem.file_readable(wp) then
                table.insert(paths, wp)
            end
        end
        if #paths > 0 then root.wallpaper_cache_preload(paths, s) end
    end

    -- Switch wallpaper on tag selection: tag name -> wallpapers/name.jpg
    for _, tag in ipairs(s.tags) do
        tag:connect_signal("property::selected", function(t)
            if t.selected then
                set_wallpaper(t.screen, t.name .. ".jpg")
            end
        end)
    end
end)

-- }}}

-- {{{ Mouse bindings
-- @DOC_ROOT_BUTTONS@
awful.mouse.append_global_mousebindings({
    -- right-click menu removed (clean desktop)
    awful.button({ }, 4, awful.tag.viewprev),
    awful.button({ }, 5, awful.tag.viewnext),
    awful.button({ modkey, altkey }, 4, function()
        awful.spawn("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+")
    end),
    awful.button({ modkey, altkey }, 5, function()
        awful.spawn("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-")
    end),    
})
-- }}}

-- {{{ Key bindings
-- @DOC_GLOBAL_KEYBINDINGS@

-- General Awesome keys
awful.keyboard.append_global_keybindings({
    awful.key({ modkey, "Control" }, "s", hotkeys_popup.show_help,
              {description="show help", group="awesome"}),
    awful.key({ modkey }, "s", function() awful.spawn("rofi -show-icons -modi window,drun -show drun") end,
              { description = "show rofi drun", group = "launcher" }),              
    awful.key({ modkey,           }, "w", function () mymainmenu:show() end,
              {description = "show main menu", group = "awesome"}),
    awful.key({ modkey, "Control" }, "r", awesome.cold_restart,
              {description = "cold restart", group = "awesome"}),
    awful.key({ modkey, "Shift"   }, "q", awesome.quit,
              {description = "quit awesome", group = "awesome"}),
    awful.key({ modkey, "Shift"   }, "Escape", function() awesome.lock() end,
              {description = "lock screen", group = "awesome"}),
    awful.key({ modkey }, "x",
              function ()
                  awful.prompt.run {
                    prompt       = "Run Lua code: ",
                    textbox      = awful.screen.focused().mypromptbox.widget,
                    exe_callback = awful.util.eval,
                    history_path = awful.util.get_cache_dir() .. "/history_eval"
                  }
              end,
              {description = "lua execute prompt", group = "awesome"}),
    awful.key({ modkey,           }, "Return", function () awful.spawn(terminal) end,
              {description = "open a terminal", group = "launcher"}),
    awful.key({ modkey },            "r",     function () awful.screen.focused().mypromptbox:run() end,
              {description = "run prompt", group = "launcher"}),
    awful.key({ modkey }, "p", function() menubar.show() end,
              {description = "show the menubar", group = "launcher"}),

    -- machi layout special keybindings
    awful.key({ modkey }, ".", function() machi.default_editor.start_interactive() end,
        { description = "machi: edit the current machi layout", group = "layout" }),
    awful.key({ modkey }, "/", function() machi.switcher.start(client.focus) end,
        { description = "machi: switch between windows", group = "layout" }), 
        
    -- Volume control (PipeWire/wpctl)
    awful.key({ modkey, altkey }, "k", function()
            awful.spawn("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+")
        end,
        { description = "volume up", group = "audio" }),
    awful.key({ modkey, altkey }, "j", function()
            awful.spawn("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-")
        end,
        { description = "volume down", group = "audio" }),
    awful.key({ modkey, altkey }, "m", function()
            awful.spawn("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle")
        end,
        { description = "toggle mute", group = "audio" }),
    awful.key({ modkey, altkey }, "0", function()
            awful.spawn("wpctl set-volume @DEFAULT_AUDIO_SINK@ 0%")
        end,
        { description = "volume 0%", group = "audio" }),

    -- Screenshots (grim + slurp)
    awful.key({ }, "Print", function()
        awful.spawn("grim ~/Pictures/screenshot-" .. os.date("%Y%m%d-%H%M%S") .. ".png")
    end, { description = "screenshot full screen", group = "screenshot" }),
    awful.key({ "Shift" }, "Print", function()
        awful.spawn.with_shell('grim -g "$(slurp)" ~/Pictures/screenshot-' .. os.date("%Y%m%d-%H%M%S") .. '.png')
    end, { description = "screenshot region (slurp)", group = "screenshot" }),
    awful.key({ "Control" }, "Print", function()
        awful.spawn.with_shell("grim - | wl-copy")
    end, { description = "screenshot to clipboard", group = "screenshot" }),
    awful.key({ "Control", "Shift" }, "Print", function()
        awful.spawn.with_shell('grim -g "$(slurp)" - | wl-copy')
    end, { description = "screenshot region to clipboard", group = "screenshot" }),
})

-- Screen recording (gpu-screen-recorder, NVENC)
-- Uses DP-3 (Dell 4K@144Hz). Output: ~/Videos/rec-YYYYMMDD-HHMMSS.mkv
-- Super+Alt+r = start/stop recording
-- Super+Alt+p = pause/resume recording
local rec_pid_file = "/tmp/gpu-screen-recorder.pid"

local function rec_is_running()
    local f = io.open(rec_pid_file, "r")
    if not f then return false end
    local pid = f:read("*l")
    f:close()
    -- check if process exists
    local check = io.open("/proc/" .. pid .. "/status", "r")
    if check then check:close(); return true end
    os.remove(rec_pid_file)
    return false
end

awful.keyboard.append_global_keybindings({
    -- Start or stop screen recording
    awful.key({ modkey, altkey }, "r", function()
        if rec_is_running() then
            -- Stop recording (SIGINT = graceful stop + save)
            awful.spawn.with_shell("kill -INT $(cat " .. rec_pid_file .. ") && rm -f " .. rec_pid_file)
            naughty.notify({ title = "Recording", text = "Stopped & saved", timeout = 3 })
        else
            local outfile = os.getenv("HOME") .. "/Videos/rec-" .. os.date("%Y%m%d-%H%M%S") .. ".mkv"
            awful.spawn.with_shell(
                "gpu-screen-recorder"
                .. " -w DP-3"
                .. " -f 144"
                .. " -k hevc"
                .. " -q very_high"
                .. " -bm vbr"
                .. " -ac opus"
                .. " -a default_output"
                .. " -fm cfr"
                .. " -cursor yes"
                .. " -cr full"
                .. " -c mkv"
                .. " -o " .. outfile
                .. " & echo $! > " .. rec_pid_file
            )
            naughty.notify({ title = "Recording", text = "Started: " .. outfile, timeout = 3 })
        end
    end, { description = "start/stop screen recording", group = "recording" }),

    -- Pause or resume screen recording
    awful.key({ modkey, altkey }, "p", function()
        if rec_is_running() then
            awful.spawn.with_shell("kill -USR2 $(cat " .. rec_pid_file .. ")")
            naughty.notify({ title = "Recording", text = "Pause/Resume toggled", timeout = 2 })
        else
            naughty.notify({ title = "Recording", text = "Not recording", timeout = 2 })
        end
    end, { description = "pause/resume recording", group = "recording" }),
})

-- Carousel layout keybindings (active only when carousel layout is selected)
local carousel = awful.layout.suit.carousel
awful.keyboard.append_global_keybindings({
    -- Scroll viewport by one column width (smooth animated scroll)
    awful.key({ modkey, "Control" }, "Left", function()
        local t = awful.screen.focused().selected_tag
        if t then carousel.scroll_by(t, -0.5) end
    end, { description = "carousel: scroll left", group = "carousel" }),
    awful.key({ modkey, "Control" }, "Right", function()
        local t = awful.screen.focused().selected_tag
        if t then carousel.scroll_by(t, 0.5) end
    end, { description = "carousel: scroll right", group = "carousel" }),
    -- Cycle column width through presets (1/3 → 1/2 → 2/3 → 1.0)
    awful.key({ modkey, "Control" }, "equal", carousel.cycle_column_width,
        { description = "carousel: cycle column width", group = "carousel" }),
    -- Adjust column width incrementally
    awful.key({ modkey, "Control" }, "minus", function() carousel.adjust_column_width(-0.1) end,
        { description = "carousel: shrink column", group = "carousel" }),
    awful.key({ modkey, "Control" }, "plus", function() carousel.adjust_column_width(0.1) end,
        { description = "carousel: grow column", group = "carousel" }),
    -- Move column left/right in the strip
    awful.key({ modkey, "Control", "Shift" }, "Left", function() carousel.move_column(-1) end,
        { description = "carousel: move column left", group = "carousel" }),
    awful.key({ modkey, "Control", "Shift" }, "Right", function() carousel.move_column(1) end,
        { description = "carousel: move column right", group = "carousel" }),
    -- Stack windows vertically in one column (consume/expel)
    awful.key({ modkey, "Control" }, "i", function() carousel.consume_window(-1) end,
        { description = "carousel: consume window from left", group = "carousel" }),
    awful.key({ modkey, "Control" }, "o", function() carousel.consume_window(1) end,
        { description = "carousel: consume window from right", group = "carousel" }),
    awful.key({ modkey, "Control" }, "e", carousel.expel_window,
        { description = "carousel: expel window to own column", group = "carousel" }),
    -- Jump to first/last column
    awful.key({ modkey, "Control" }, "Home", carousel.focus_first_column,
        { description = "carousel: focus first column", group = "carousel" }),
    awful.key({ modkey, "Control" }, "End", carousel.focus_last_column,
        { description = "carousel: focus last column", group = "carousel" }),
})

-- Enable 3-finger swipe gesture for carousel viewport panning
pcall(function() carousel.make_gesture_binding() end)

-- Tags related keybindings
awful.keyboard.append_global_keybindings({
    awful.key({ modkey,           }, "Left",   awful.tag.viewprev,
              {description = "view previous", group = "tag"}),
    awful.key({ modkey,           }, "Right",  awful.tag.viewnext,
              {description = "view next", group = "tag"}),
    awful.key({ modkey,           }, "Escape", awful.tag.history.restore,
              {description = "go back", group = "tag"}),
})

-- Focus related keybindings
awful.keyboard.append_global_keybindings({
    awful.key({ modkey,           }, "j",
        function ()
            awful.client.focus.byidx( 1)
        end,
        {description = "focus next by index", group = "client"}
    ),
    awful.key({ modkey,           }, "k",
        function ()
            awful.client.focus.byidx(-1)
        end,
        {description = "focus previous by index", group = "client"}
    ),
    awful.key({ modkey,           }, "Tab",
        function ()
            awful.client.focus.history.previous()
            if client.focus then
                client.focus:raise()
            end
        end,
        {description = "go back", group = "client"}),
    awful.key({ modkey, "Control" }, "j", function () awful.screen.focus_relative( 1) end,
              {description = "focus the next screen", group = "screen"}),
    awful.key({ modkey, "Control" }, "k", function () awful.screen.focus_relative(-1) end,
              {description = "focus the previous screen", group = "screen"}),
    awful.key({ modkey, "Control" }, "n",
              function ()
                  local c = awful.client.restore()
                  -- Focus restored client
                  if c then
                    c:activate { raise = true, context = "key.unminimize" }
                  end
              end,
              {description = "restore minimized", group = "client"}),
})

-- Layout related keybindings
awful.keyboard.append_global_keybindings({
    awful.key({ modkey, "Shift"   }, "j", function () awful.client.swap.byidx(  1)    end,
              {description = "swap with next client by index", group = "client"}),
    awful.key({ modkey, "Shift"   }, "k", function () awful.client.swap.byidx( -1)    end,
              {description = "swap with previous client by index", group = "client"}),
    awful.key({ modkey,           }, "u", awful.client.urgent.jumpto,
              {description = "jump to urgent client", group = "client"}),
    awful.key({ modkey,           }, "l",     function () awful.tag.incmwfact( 0.05)          end,
              {description = "increase master width factor", group = "layout"}),
    awful.key({ modkey,           }, "h",     function () awful.tag.incmwfact(-0.05)          end,
              {description = "decrease master width factor", group = "layout"}),
    awful.key({ modkey, "Shift"   }, "h",     function () awful.tag.incnmaster( 1, nil, true) end,
              {description = "increase the number of master clients", group = "layout"}),
    awful.key({ modkey, "Shift"   }, "l",     function () awful.tag.incnmaster(-1, nil, true) end,
              {description = "decrease the number of master clients", group = "layout"}),
    awful.key({ modkey, "Control" }, "h",     function () awful.tag.incncol( 1, nil, true)    end,
              {description = "increase the number of columns", group = "layout"}),
    awful.key({ modkey, "Control" }, "l",     function () awful.tag.incncol(-1, nil, true)    end,
              {description = "decrease the number of columns", group = "layout"}),
    awful.key({ modkey,           }, "space", function () awful.layout.inc( 1)                end,
              {description = "select next", group = "layout"}),
    awful.key({ modkey, "Shift"   }, "space", function () awful.layout.inc(-1)                end,
              {description = "select previous", group = "layout"}),
})

-- @DOC_NUMBER_KEYBINDINGS@

awful.keyboard.append_global_keybindings({
    awful.key {
        modifiers   = { modkey },
        keygroup    = "numrow",
        description = "only view tag",
        group       = "tag",
        on_press    = function (index)
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
        on_press    = function (index)
            local screen = awful.screen.focused()
            local tag = screen.tags[index]
            if tag then
                awful.tag.viewtoggle(tag)
            end
        end,
    },
    awful.key {
        modifiers = { modkey, "Shift" },
        keygroup    = "numrow",
        description = "move focused client to tag",
        group       = "tag",
        on_press    = function (index)
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
        on_press    = function (index)
            if client.focus then
                local tag = client.focus.screen.tags[index]
                if tag then
                    client.focus:toggle_tag(tag)
                end
            end
        end,
    },
    awful.key {
        modifiers   = { modkey },
        keygroup    = "numpad",
        description = "select layout directly",
        group       = "layout",
        on_press    = function (index)
            local t = awful.screen.focused().selected_tag
            if t then
                t.layout = t.layouts[index] or t.layout
            end
        end,
    }
})

-- @DOC_CLIENT_BUTTONS@
client.connect_signal("request::default_mousebindings", function()
    awful.mouse.append_client_mousebindings({
        awful.button({ }, 1, function (c)
            c:activate { context = "mouse_click" }
        end),
        awful.button({ modkey }, 1, function (c)
            c:activate { context = "mouse_click", action = "mouse_move"  }
        end),
        awful.button({ modkey }, 3, function (c)
            c:activate { context = "mouse_click", action = "mouse_resize"}
        end),
    })
end)

-- @DOC_CLIENT_KEYBINDINGS@
client.connect_signal("request::default_keybindings", function()
    awful.keyboard.append_client_keybindings({
        awful.key({ modkey,           }, "f",
            function (c)
                c.fullscreen = not c.fullscreen
                c:raise()
            end,
            {description = "toggle fullscreen", group = "client"}),
        awful.key({ modkey, "Shift"   }, "c",      function (c) c:kill()                         end,
                {description = "close", group = "client"}),
        awful.key({ modkey, "Control" }, "space",  awful.client.floating.toggle                     ,
                {description = "toggle floating", group = "client"}),
        awful.key({ modkey, "Control" }, "Return", function (c) c:swap(awful.client.getmaster()) end,
                {description = "move to master", group = "client"}),
        awful.key({ modkey,           }, "o",      function (c) c:move_to_screen()               end,
                {description = "move to screen", group = "client"}),
        awful.key({ modkey, "Control" }, "t",      function (c) c.ontop = not c.ontop            end,
                {description = "toggle keep on top", group = "client"}),
        -- show/hide titlebar
        awful.key({ modkey }, "t", awful.titlebar.toggle,
                { description = "Show/Hide Titlebars", group = "client" }),                
        awful.key({ modkey,           }, "n",
            function (c)
                -- Fade out then minimize
                local anim = require("anim_client")
                anim.fade_minimize(c)
            end ,
            {description = "minimize", group = "client"}),
        awful.key({ modkey,           }, "m",
            function (c)
                c.maximized = not c.maximized
                c:raise()
            end ,
            {description = "(un)maximize", group = "client"}),
        awful.key({ modkey, "Control" }, "m",
            function (c)
                c.maximized_vertical = not c.maximized_vertical
                c:raise()
            end ,
            {description = "(un)maximize vertically", group = "client"}),
        awful.key({ modkey, "Shift"   }, "m",
            function (c)
                c.maximized_horizontal = not c.maximized_horizontal
                c:raise()
            end ,
            {description = "(un)maximize horizontally", group = "client"}),
    })
end)

-- Steam bug with window outside of the screen
client.connect_signal("property::position", function(c)
    if c.class == 'Steam' then
        local g = c.screen.geometry
        if c.y + c.height > g.height then
            c.y = g.height - c.height
            naughty.notify {
                text = "restricted window: " .. c.name,
            }
        end
        if c.x + c.width > g.width then
            c.x = g.width - c.width
        end
    end
end)

-- mpv: update aspect ratio when video changes (playlist advancement).
-- mpv resizes the window to match the new video's native dimensions,
-- which emits property::size. We recapture the ratio so subsequent
-- user resizes maintain the new video's proportions.
-- This is safe during user resize too — the C-level aspect_ratio
-- enforcement means width/height already matches the current ratio,
-- so recalculating it is idempotent (same value within rounding).
client.connect_signal("property::size", function(c)
    if c.class == "mpv" and c.floating and not c.fullscreen
            and not c.maximized and c.width > 0 and c.height > 0 then
        local bw2 = 2 * (c.border_width or 0)
        local cw = c.width - bw2
        local ch = c.height - bw2
        if cw > 0 and ch > 0 then
            c.aspect_ratio = cw / ch
        end
    end
end)

-- }}}

-- {{{ Rules
-- Rules to apply to new clients.
ruled.client.connect_signal("request::rules", function()
    -- All clients will match this rule.
    ruled.client.append_rule {
        id         = "global",
        rule       = {},
        properties = {
            focus     = awful.client.focus.filter,
            raise     = true,
            screen    = awful.screen.preferred,
            placement = awful.placement.no_overlap + awful.placement.no_offscreen
        }
    }

    -- Add titlebars to normal clients and dialogs
    ruled.client.append_rule {
        id         = "dialogs",
        rule_any   = { type = { "dialog" } },
        except_any = {
            -- place here exceptions for special dialogs windows
        },
        properties = { floating = true },
        callback   = function(c)
            awful.placement.centered(c, nil)
        end
    }

    -- All Dialogs are floating and center
    ruled.client.append_rule {
        id         = "titlebars",
        rule_any   = { type = { "normal", "dialog" } },
        properties = { titlebars_enabled = true }
    }

    ruled.client.append_rule {
        id         = "floating",
        rule_any   = {
            name = { "Ulauncher - Application Launcher" },
        },
        properties = {
            focus        = awful.client.focus.filter,
            raise        = true,
            screen       = awful.screen.preferred,
            border_width = 0,
        }
    }

    -- Floating clients.
    ruled.client.append_rule {
        id         = "floating",
        rule_any   = {
            instance = { "copyq", "pinentry" },
            class    = {
                "Arandr", "Blueman-manager", "Gpick", "Kruler", "Sxiv",
                "Tor Browser", "Wpa_gui", "veromix", "xtightvncviewer",
                "Pamac-manager",
                "Polkit-gnome-authentication-agent-1",
                "Polkit-kde-authentication-agent-1",
                "Gcr-prompter",
            },
            -- Note that the name property shown in xprop might be set slightly after creation of the client
            -- and the name shown there might not match defined rules here.
            name     = {
                "Event Tester", -- xev.
                "Remmina Remote Desktop Client",
                "win0",
            },
            role     = {
                "AlarmWindow",   -- Thunderbird's calendar.
                "ConfigManager", -- Thunderbird's about:config.
                "pop-up",        -- e.g. Google Chrome's (detached) Developer Tools.
            }
        },
        properties = { floating = true },
        callback   = function(c)
            awful.placement.centered(c, nil)
        end
    }

    -- FullHD Resolution for Specific Apps
    ruled.client.append_rule {
        id         = "dialogs",
        rule_any   = {
            instance = { "remmina", }
        },
        except_any = {
            name = {
                "Remmina Remote Desktop Client"
            }
        },
        properties = { floating = true },
        callback   = function(c)
            c.width = 1980
            c.height = 1080
            awful.placement.centered(c, nil)
        end
    }

    -- mpv: floating with aspect ratio preservation
    ruled.client.append_rule {
        rule_any   = {
            class = { "mpv" },
        },
        properties = {
            floating  = true,
            titlebars_enabled = true,
        },
        callback   = function(c)
            -- Set initial aspect ratio from video content dimensions.
            -- c.width/c.height is full geometry (incl. borders), so subtract
            -- borders to get the content (surface) size matching the video.
            local bw2 = 2 * (c.border_width or 0)
            local cw = c.width - bw2
            local ch = c.height - bw2
            if cw > 0 and ch > 0 then
                c.aspect_ratio = cw / ch
            end
            awful.placement.centered(c, nil)
        end
    }

    -- Set Blender to always map on the tag 4 in screen 1.
    ruled.client.append_rule {
        rule_any   = {
            name = { "Blender" }
        },
        properties = {
            tag = screen[1].tags[4],
        },
    }

    -- Set Obsidian to always map on the tag 2 in screen 1.
    ruled.client.append_rule {
        rule_any   = {
            name = { "Obsidian" }
        },
        properties = {
            tag = screen[1].tags[2],
        },
    }

    ruled.client.append_rule {
        rule_any = {
            name = { "GLava" }
        },
        properties = {
            focusable = false,
            ontop = true,
            skip_taskbar = true
        },
        callback = function(c)
            local img = cairo.ImageSurface(cairo.Format.A1, 0, 0)
            c.shape_input = img._native
            img.finish()
        end
    }
end)

-- }}}

client.connect_signal("manage", function(c)
    -- Similar behaviour as other window managers DWM, XMonad.
    -- Master-Slave layout new client goes to the slave, master is kept
    -- If you need new slave as master press: ctrl + super + return
    if not awesome.startup then c:to_secondary_section() end
end)

-- {{{ Titlebars
-- @DOC_TITLEBARS@
-- Add a titlebar if titlebars_enabled is set to true in the rules.
client.connect_signal("request::titlebars", function(c)
    -- buttons for the titlebar
    local buttons = {
        awful.button({ }, 1, function()
            c:activate { context = "titlebar", action = "mouse_move"  }
        end),
        awful.button({ }, 3, function()
            c:activate { context = "titlebar", action = "mouse_resize"}
        end),
    }

    awful.titlebar(c).widget = {
        { -- Left
            awful.titlebar.widget.iconwidget(c),
            buttons = buttons,
            layout  = wibox.layout.fixed.horizontal
        },
        { -- Middle
            { -- Title
                halign = "center",
                widget = awful.titlebar.widget.titlewidget(c)
            },
            buttons = buttons,
            layout  = wibox.layout.flex.horizontal
        },
        { -- Right
            awful.titlebar.widget.floatingbutton (c),
            awful.titlebar.widget.maximizedbutton(c),
            awful.titlebar.widget.stickybutton   (c),
            awful.titlebar.widget.ontopbutton    (c),
            awful.titlebar.widget.closebutton    (c),
            layout = wibox.layout.fixed.horizontal()
        },
        layout = wibox.layout.align.horizontal
    }
    awful.titlebar.hide(c)
end)
-- }}}

-- {{{ Notifications

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
            opacity          = 0.9,
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
            opacity          = 0.9,
        }
    }
end)

naughty.connect_signal("request::display", function(n)
    -- Pick icon for display without modifying n.icon (avoids signal loops)
    local display_icon = n.icon
    if type(display_icon) == "string" then
        -- String: only accept absolute paths, otherwise use default
        if display_icon == "" or display_icon:sub(1,1) ~= "/" then
            display_icon = beautiful.notification_icon_default
        end
    elseif not display_icon then
        -- Nil: use default
        display_icon = beautiful.notification_icon_default
    end
    -- Otherwise (cairo surface, userdata) — keep as-is

    naughty.layout.box {
        notification = n,
        shape = function(cr, w, h)
            gears.shape.rounded_rect(cr, w, h, dpi(6))
        end,
        widget_template = {
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
        },
    }
end)

-- }}}

-- Enable sloppy focus, so that focus follows mouse.
client.connect_signal("mouse::enter", function(c)
    c:activate { context = "mouse_enter", raise = false }
end)

-- {{{ Autostart
-- Use spawn.once to prevent duplicates on config reload
awful.spawn.once("nm-applet")
-- awful.spawn.once("pasystray")  -- replaced by native volume_widget
-- awful.spawn.once("blueman-applet")
-- awful.spawn.once("copyq")
-- }}}

-- SceneFX visual effects are configured via anim_client.enable() below.
-- See the scenefx = { ... } section in the enable() call.

-- Enable client animations (must be last — after all other signal handlers)
-- All values below are defaults — remove or change as needed.
-- Disable all: enabled = false. Disable one: fade = { enabled = false }.
-- Theme overrides (beautiful.anim_<type>_<param>) take priority over these.
pcall(function()
    require("anim_client").enable({
        enabled = true,             -- global kill switch

        maximize = {
            enabled  = true,        -- animate maximize / restore
            duration = 0.25,        -- seconds
            easing   = "ease-out-cubic",
        },
        fullscreen = {
            enabled  = true,        -- animate fullscreen / restore
            duration = 0.25,
            easing   = "ease-out-cubic",
        },
        fade = {
            enabled      = true,    -- fadeIn on new window + restore from minimize
            duration     = 0.5,
            out_duration = nil,     -- fadeOut duration (nil = same as duration)
            easing       = "ease-out-cubic",
        },
        minimize = {
            enabled  = true,        -- fadeOut on minimize (Super+N)
            duration = 0.4,
            easing   = "ease-out-cubic",
        },
        layer = {
            enabled  = true,        -- fadeIn for layer surfaces (rofi, launchers)
            duration = 0.2,         -- shorter — popups should feel snappy
            easing   = "ease-out-cubic",
        },
        dialog = {
            enabled  = true,        -- fadeIn for dialog/transient windows
            duration = 0.2,
            easing   = "ease-out-cubic",
        },
        swap = {
            enabled  = true,        -- tiling swap animation (Super+Shift+J/K)
            duration = 0.25,        -- skipped in carousel/machi/max layouts
            easing   = "ease-out-cubic",
        },
        float = {
            enabled  = true,        -- float toggle animation (Ctrl+Super+Space)
            duration = 0.3,         -- skipped in carousel/machi/max layouts
            easing   = "ease-out-cubic",
        },
        layout = {
            enabled  = true,        -- mwfact, spawn/kill reflow, layout switch
            duration = 0.15,        -- short — background reflow should be quick
            easing   = "ease-out-cubic",
        },
        scenefx = {
            enabled       = true,   -- set false to disable all scenefx effects
            corner_radius = 14,     -- pixels, 0 = sharp corners
            blur_enabled  = true,   -- backdrop blur (visible when opacity < 1.0)
            blur_opacity  = 0.75,   -- opacity for blur-enabled clients (lower = more see-through)
            blur_classes  = {       -- classes that get blur + transparency
                "Alacritty", "ghostty", "kitty", "foot",
                "Rofi",
            },
            no_corners    = {       -- classes with sharp corners (games, XWayland)
                "steam_app_*", "Wine", "Xwayland",
            },
        },
        -- NOTE: Do NOT require("somewm.layout_animation") — our anim_client
        -- handles all layout transitions. Both modules write _set_geometry_silent()
        -- on tiled clients and would conflict.
    })
end)

-- Tag slide animation (KDE-style Desktop Slide on Super+Left/Right)
-- Config priority: beautiful.tag_slide_<param> > these values > module defaults
pcall(function()
    require("somewm.tag_slide").enable({
        duration  = 0.25,
        easing    = "ease-out-cubic",
        wallpaper = { enabled = true },
    })
end)
