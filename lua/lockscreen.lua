---------------------------------------------------------------------------
--- Default lockscreen module for somewm.
--
-- Provides a simple but complete lockscreen with visual feedback.
-- Creates one wibox per screen: an interactive wibox with password UI on the
-- primary screen, and opaque cover wiboxes on all other screens.
--
-- Usage:
--    require("lockscreen").init()
--    -- Then bind awesome.lock to a key, e.g.:
--    awful.key({ modkey, "Shift" }, "Escape", awesome.lock)
--
-- @module lockscreen
---------------------------------------------------------------------------

local wibox = require("wibox")
local awful = require("awful")
local gears = require("gears")
local beautiful = require("beautiful")

local lockscreen = {}

-- State
local initialized = false
local surfaces = {}  -- keyed by screen
local interactive_screen = nil
local password = ""
local grabber = nil

-- Widget references (for interactive surface)
local password_dots = nil
local status_text = nil
local clock = nil

-- Configuration (populated in init after beautiful is loaded)
local config = {}

-- Default values
local defaults = {
    bg_color     = "#1a1a2e",
    fg_color     = "#e0e0e0",
    input_bg     = "#2a2a4e",
    border_color = "#4a4a6e",
    error_color  = "#ff6b6b",
    font         = "sans 14",
    font_large   = "sans bold 48",
    clock_format = "%H:%M",
    date_format  = "%A, %B %d",
    lock_screen  = false,  -- screen object or function()->screen; default: screen.primary
    bg_image     = false,  -- path to background image (covers entire screen, dimmed by overlay)
    bg_image_overlay = "#000000aa",  -- semi-transparent overlay on top of bg_image (67% opacity)
}

-- Count UTF-8 codepoints in a string (LuaJIT lacks the utf8 library)
local function utf8_len(s)
    local count = 0
    for i = 1, #s do
        local b = s:byte(i)
        if b < 0x80 or b >= 0xC0 then
            count = count + 1
        end
    end
    return count
end

-- Check if Caps Lock modifier is active
local function has_caps_lock(modifiers)
    for _, mod in ipairs(modifiers) do
        if mod == "Lock" then return true end
    end
    return false
end

-- Helper to set status text with color
local function set_status(text, is_error)
    if not status_text then return end
    local color = is_error and config.error_color or config.fg_color
    status_text.markup = string.format('<span foreground="%s">%s</span>', color, text)
end

-- Build the interactive layout (clock + date + password + status)
local function build_interactive_layout()
    clock = wibox.widget({
        format = config.clock_format,
        font = config.font_large,
        halign = "center",
        widget = wibox.widget.textclock,
    })

    local date_widget = wibox.widget({
        format = config.date_format,
        font = config.font,
        halign = "center",
        widget = wibox.widget.textclock,
    })

    password_dots = wibox.widget({
        text = "",
        font = config.font,
        halign = "center",
        valign = "center",
        widget = wibox.widget.textbox,
    })

    status_text = wibox.widget({
        text = "Enter password to unlock",
        font = config.font,
        halign = "center",
        widget = wibox.widget.textbox,
    })

    local input_box = wibox.widget({
        {
            {
                password_dots,
                left = 20,
                right = 20,
                top = 12,
                bottom = 12,
                widget = wibox.container.margin,
            },
            bg = config.input_bg,
            widget = wibox.container.background,
        },
        margins = 2,
        color = config.border_color,
        widget = wibox.container.margin,
    })

    local input_container = wibox.widget({
        input_box,
        forced_width = 280,
        forced_height = 48,
        widget = wibox.container.constraint,
    })

    -- Content overlay with centered UI
    local content = wibox.widget({
        {
            {
                {
                    clock,
                    fg = config.fg_color,
                    widget = wibox.container.background,
                },
                {
                    date_widget,
                    fg = config.fg_color,
                    widget = wibox.container.background,
                },
                {
                    forced_height = 40,
                    widget = wibox.container.background,
                },
                {
                    input_container,
                    halign = "center",
                    widget = wibox.container.place,
                },
                {
                    {
                        status_text,
                        fg = config.fg_color,
                        widget = wibox.container.background,
                    },
                    top = 16,
                    widget = wibox.container.margin,
                },
                spacing = 8,
                layout = wibox.layout.fixed.vertical,
            },
            halign = "center",
            valign = "center",
            widget = wibox.container.place,
        },
        bg = config.bg_image and config.bg_image_overlay or config.bg_color,
        widget = wibox.container.background,
    })

    -- If bg_image is set, use imagebox as base layer with overlay on top
    if config.bg_image then
        local img = gears.surface.load_uncached_silently(config.bg_image)
        if img then
            return wibox.widget({
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

    return content
end

-- Determine which screen should get the interactive lock UI
local function get_interactive_screen()
    if config.lock_screen then
        if type(config.lock_screen) == "function" then
            return config.lock_screen()
        end
        return config.lock_screen
    end
    return screen.primary
end

-- Build a cover layout for non-interactive screens
local function build_cover_layout()
    if config.bg_image then
        local img = gears.surface.load_uncached_silently(config.bg_image)
        if img then
            return wibox.widget({
                {
                    image = img,
                    resize = true,
                    horizontal_fit_policy = "fit",
                    vertical_fit_policy = "fit",
                    upscale = true,
                    downscale = true,
                    widget = wibox.widget.imagebox,
                },
                {
                    bg = config.bg_image_overlay,
                    widget = wibox.container.background,
                },
                layout = wibox.layout.stack,
            })
        end
    end
    return nil
end

-- Create a cover wibox for a non-interactive screen
local function create_cover(s)
    local wb = wibox({
        visible = false,
        ontop = true,
        bg = config.bg_image and "#00000000" or config.bg_color,
        x = s.geometry.x,
        y = s.geometry.y,
        width = s.geometry.width,
        height = s.geometry.height,
        widget = build_cover_layout(),
    })
    awesome.add_lock_cover(wb)
    return wb
end

-- Create the interactive wibox for the password screen
local function create_interactive(s)
    local layout = build_interactive_layout()
    local wb = wibox({
        visible = false,
        ontop = true,
        bg = config.bg_image and "#00000000" or config.bg_color,
        x = s.geometry.x,
        y = s.geometry.y,
        width = s.geometry.width,
        height = s.geometry.height,
        widget = layout,
    })
    awesome.set_lock_surface(wb)
    return wb
end

local function set_visibility_all_surfaces(visible)
    for _, wb in pairs(surfaces) do
        wb.visible = visible
    end
end

-- Rebuild all lock surfaces for current screen layout
local function rebuild_surfaces()
    -- Clean up existing surfaces
    set_visibility_all_surfaces(false)
    awesome.clear_lock_covers()
    surfaces = {}

    interactive_screen = get_interactive_screen()

    for s in screen do
        if s == interactive_screen then
            surfaces[s] = create_interactive(s)
        else
            surfaces[s] = create_cover(s)
        end
    end
end

--- Initialize the lockscreen module
-- @tparam[opt] table opts Configuration options
function lockscreen.init(opts)
    if initialized then return end
    initialized = true

    opts = opts or {}

    -- Resolve config: opts > beautiful.lockscreen_* > beautiful core > defaults
    local theme_fallbacks = {
        bg_color     = "bg_normal",
        fg_color     = "fg_normal",
        input_bg     = "bg_focus",
        border_color = "border_color_active",
        error_color  = "bg_urgent",
    }
    for k, default in pairs(defaults) do
        config[k] = (opts[k])
            or beautiful["lockscreen_" .. k]
            or (theme_fallbacks[k] and beautiful[theme_fallbacks[k]])
            or default
    end
    -- Special case: font fallback to beautiful.font
    if not opts.font and not beautiful.lockscreen_font then
        config.font = beautiful.font or defaults.font
    end
    -- lock_screen is not a beautiful property
    if opts.lock_screen ~= nil then
        config.lock_screen = opts.lock_screen
    end

    -- Build surfaces for all screens
    rebuild_surfaces()

    -- Handle screen hotplug
    screen.connect_signal("added", function(s)
        if not surfaces[s] then
            surfaces[s] = create_cover(s)
            -- If we're currently locked, show the new cover immediately
            if awesome.locked then
                surfaces[s].visible = true
            end
        end
    end)

    screen.connect_signal("removed", function(s)
        local wb = surfaces[s]
        if wb then
            wb.visible = false
            if s == interactive_screen then
                -- Interactive screen removed during lock - migrate
                awesome.clear_lock_surface()
                surfaces[s] = nil
                -- Pick a new interactive screen
                interactive_screen = screen.primary or screen[1]
                if interactive_screen and not surfaces[interactive_screen] then
                    surfaces[interactive_screen] = create_interactive(interactive_screen)
                    if awesome.locked then
                        surfaces[interactive_screen].visible = true
                    end
                elseif interactive_screen and surfaces[interactive_screen] then
                    -- Convert existing cover to interactive
                    awesome.remove_lock_cover(surfaces[interactive_screen])
                    surfaces[interactive_screen] = create_interactive(interactive_screen)
                    if awesome.locked then
                        surfaces[interactive_screen].visible = true
                    end
                end
            else
                awesome.remove_lock_cover(wb)
                surfaces[s] = nil
            end
        end
    end)

    -- Handle lock activation
    awesome.connect_signal("lock::activate", function()
        password = ""
        if password_dots then password_dots.text = "" end
        set_status("Enter password to unlock", false)

        -- Show all lock surfaces
        set_visibility_all_surfaces(true)

        grabber = awful.keygrabber({
            autostart = true,
            stop_key = nil,
            -- The code path "append input key to password" below can deal with
            -- modkey input as well, i.e., it is filtered out. However, by masking
            -- them right away, it is computationally more efficient.
            mask_modkeys = true,
            keypressed_callback = function(_, mod, key, _)
                if key == "Return" then
                    set_status("Verifying...", false)
                    gears.timer.start_new(0.05, function()
                        if awesome.authenticate(password) then
                            awesome.unlock()
                        else
                            password = ""
                            if password_dots then password_dots.text = "" end
                            set_status("Wrong password, try again", true)
                            gears.timer.start_new(2, function()
                                if awesome.locked then
                                    set_status("Enter password to unlock", false)
                                end
                                return false
                            end)
                        end
                        return false
                    end)
                elseif key == "BackSpace" then
                    if #password > 0 then
                        -- Keygrabber delivers one character per event, so
                        -- removing the last byte-sequence added is sufficient.
                        -- Walk backwards past any UTF-8 continuation bytes.
                        local i = #password
                        while i > 1 and password:byte(i) >= 0x80
                              and password:byte(i) < 0xC0 do
                            i = i - 1
                        end
                        password = password:sub(1, i - 1)
                    end
                    if password_dots then
                        password_dots.text = string.rep("\xE2\x97\x8F", utf8_len(password))
                    end
                elseif key == "Escape" then
                    password = ""
                    if password_dots then password_dots.text = "" end
                -- Append input key to password
                elseif #key >= 1 and key:byte(1) >= 0x20 then
                    if #password > 256 then return end
                    -- Only append single-character keys (which may still have
                    -- a multi-byte UTF-8 encoding), but do not add control
                    -- keys like "Shift_R" to password.
                    if utf8_len(key) > 1 then return end
                    password = password .. key
                    if password_dots then
                        password_dots.text = string.rep("\xE2\x97\x8F", utf8_len(password))
                    end
                end
                -- Show caps lock warning when typing (but not over error messages)
                if mod and has_caps_lock(mod) and awesome.locked then
                    if not status_text or not status_text.markup
                        or not status_text.markup:find("Wrong password") then
                        set_status("Caps Lock is on", true)
                    end
                elseif password == "" and key ~= "Return" then
                    set_status("Enter password to unlock", false)
                end
            end,
        })
    end)

    -- Handle unlock
    awesome.connect_signal("lock::deactivate", function()
        set_visibility_all_surfaces(false)
        password = ""
        if password_dots then password_dots.text = "" end
        if grabber then
            grabber:stop()
            grabber = nil
        end
    end)
end

return lockscreen
