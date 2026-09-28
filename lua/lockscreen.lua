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

-- lgi/cairo is loaded lazily (only when blur is requested) so the
-- lockscreen still works on minimal systems without it, in plain
-- color or plain image modes.
local _cairo
local function get_cairo()
    if _cairo ~= nil then return _cairo or nil end
    local ok, lgi = pcall(require, "lgi")
    if not ok or not lgi then _cairo = false; return nil end
    _cairo = lgi.cairo or false
    return _cairo or nil
end

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
    bg_image     = false,  -- path to wallpaper image (covers entire screen, dimmed by overlay)
    bg_image_overlay = "#000000aa",  -- semi-transparent overlay on top of bg_image (67% opacity)
    bg_image_blur = false,  -- false | true | number | table | function(surface)->surface; see normalize_blur_spec below
}

-- Default blur parameters when user passes `true` or just a number.
local DEFAULT_BLUR_RADIUS = 15
local DEFAULT_BLUR_PASSES = 3

-- Sanity clamps so a stray `bg_image_blur = 10000` doesn't hang the
-- lockscreen render with pathological allocations.
local BLUR_RADIUS_MAX = 100
local BLUR_PASSES_MAX = 10

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- Duck-typed check: does this value look like a cairo ImageSurface we can
-- draw from? Used to validate the return value of user-supplied blur
-- functions before handing them back into the wibox render pipeline.
local function is_renderable_surface(s)
    return type(s) == "userdata"
        and type(s.get_width) == "function"
        and type(s.get_height) == "function"
end

-- Multi-pass bilinear downscale/upscale blur. This is not a true Gaussian
-- kernel but produces a visually convincing soft blur at negligible cost,
-- which is ideal for a one-shot lockscreen render. Each pass shrinks the
-- surface by `scale` and expands back with bilinear sampling; stacking
-- several passes approximates a Gaussian response.
local function multipass_blur(surface, radius, passes)
    if not surface then return surface end
    local cairo = get_cairo()
    if not cairo then return surface end  -- lgi not installed: no-op

    radius = clamp(tonumber(radius) or DEFAULT_BLUR_RADIUS, 1, BLUR_RADIUS_MAX)
    passes = clamp(math.floor(tonumber(passes) or DEFAULT_BLUR_PASSES),
                   1, BLUR_PASSES_MAX)

    local w = surface:get_width()
    local h = surface:get_height()
    if w <= 0 or h <= 0 then return surface end

    -- Scale factor per pass: larger radius ⇒ more aggressive downscale.
    -- Divide by `passes` so multi-pass and single-pass roughly agree on
    -- perceived blur strength.
    local scale = math.max(2, radius / passes)

    local current = surface
    for _ = 1, passes do
        local sw = math.max(1, math.floor(w / scale))
        local sh = math.max(1, math.floor(h / scale))

        local small = cairo.ImageSurface.create(cairo.Format.ARGB32, sw, sh)
        local cr = cairo.Context(small)
        cr:scale(sw / w, sh / h)
        local down_pat = cairo.Pattern.create_for_surface(current)
        down_pat:set_filter(cairo.Filter.GOOD)
        cr:set_source(down_pat)
        cr:paint()

        local expanded = cairo.ImageSurface.create(cairo.Format.ARGB32, w, h)
        local cr2 = cairo.Context(expanded)
        cr2:scale(w / sw, h / sh)
        local up_pat = cairo.Pattern.create_for_surface(small)
        up_pat:set_filter(cairo.Filter.GOOD)
        cr2:set_source(up_pat)
        cr2:paint()

        -- Explicitly finish intermediates. `:finish()` releases the cairo
        -- surface's backing memory synchronously (instead of waiting for
        -- Lua GC to run the LGI __gc metamethod). We must NOT finish the
        -- caller's original `surface` — only intermediates we allocated.
        small:finish()
        if current ~= surface then
            current:finish()
        end

        current = expanded
    end
    return current
end

-- Normalize any user-supplied blur spec into a concrete transform function.
-- Accepted forms (permissive on purpose — somewm is used by programmers
-- who expect APIs to "do the right thing"):
--
--   false | nil                     -- no blur
--   true                            -- default blur (radius=15, passes=3)
--   <number>                        -- radius, default passes
--   { radius = N, passes = M }      -- explicit control
--   function(surface) -> surface    -- fully custom transform
--
-- Returns nil when blur is disabled, otherwise a function(surface)->surface.
local function normalize_blur_spec(spec)
    if spec == nil or spec == false then return nil end
    if type(spec) == "function" then return spec end
    if spec == true then
        return function(s) return multipass_blur(s, DEFAULT_BLUR_RADIUS, DEFAULT_BLUR_PASSES) end
    end
    if type(spec) == "number" then
        if spec <= 0 then return nil end
        return function(s) return multipass_blur(s, spec, DEFAULT_BLUR_PASSES) end
    end
    if type(spec) == "table" then
        local radius = tonumber(spec.radius) or DEFAULT_BLUR_RADIUS
        local passes = tonumber(spec.passes) or DEFAULT_BLUR_PASSES
        if radius <= 0 or passes <= 0 then return nil end
        return function(s) return multipass_blur(s, radius, passes) end
    end
    return nil  -- unknown form: silently disable rather than crash lockscreen
end

-- Cache blurred surfaces keyed by (image path, blur spec signature) so we
-- don't rerun the blur pipeline per monitor, per rebuild_surfaces(), or per
-- lock. Misses are cached too (as `false`) to avoid reloading a known-bad
-- path on every call.
local bg_surface_cache = {}

local function spec_signature(spec)
    local t = type(spec)
    if t == "table" then
        return string.format("t|%s|%s", tostring(spec.radius),
                             tostring(spec.passes))
    end
    if t == "function" then return "fn|" .. tostring(spec) end
    return t .. "|" .. tostring(spec)
end

-- Resolve bg_image to a cairo surface (or nil if not set / failed to load).
-- When bg_image_blur is set, the surface is transformed through the
-- normalized blur function before being returned.
--
-- The blurred surface is cached for built-in blur specs (true/number/table)
-- so the pipeline doesn't re-run per monitor or per rebuild. Custom
-- function specs are NOT cached — user callbacks may close over mutable
-- state and expect to run each time. Callers who want to force a refresh
-- (e.g. after swapping the image file at the same path) can call
-- `lockscreen.invalidate_bg_cache()`.
local function load_bg_image()
    if not config.bg_image then return nil end

    local cacheable = type(config.bg_image_blur) ~= "function"
    local key
    if cacheable then
        key = tostring(config.bg_image) .. "|"
            .. spec_signature(config.bg_image_blur)
        local cached = bg_surface_cache[key]
        if cached ~= nil then
            return cached or nil
        end
    end

    local surface = gears.surface.load_uncached_silently(config.bg_image)
    if not surface then
        if cacheable then bg_surface_cache[key] = false end
        return nil
    end

    local blur_fn = normalize_blur_spec(config.bg_image_blur)
    if blur_fn then
        local ok, result = pcall(blur_fn, surface)
        if ok and is_renderable_surface(result) then
            surface = result
        end
        -- If blur failed or returned garbage we silently keep the original
        -- surface — a crisp wallpaper is a better fallback than a black
        -- lockscreen.
    end

    if cacheable then bg_surface_cache[key] = surface end
    return surface
end

--- Drop the cached bg_image surface(s). Call this if you swap the wallpaper
-- file on disk at the same path without changing the config.
function lockscreen.invalidate_bg_cache()
    bg_surface_cache = {}
end

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

    local ui_content = wibox.widget({
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
    })

    -- Two-layer structure: wibox.container.background paints bg *under* bgimage,
    -- so a single layer with bg=overlay + bgimage=wallpaper would put the dim
    -- beneath the image and it would be invisible. Place the overlay on an
    -- inner background so it paints *over* the outer's bgimage — children are
    -- drawn after the parent's bg+bgimage pass.
    local bg_image_surface = load_bg_image()
    return wibox.widget({
        {
            ui_content,
            bg = bg_image_surface and config.bg_image_overlay or config.bg_color,
            widget = wibox.container.background,
        },
        bgimage = bg_image_surface,
        widget = wibox.container.background,
    })
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

-- Create a cover wibox for a non-interactive screen
local function create_cover(s)
    local bg_image_surface = load_bg_image()
    local wb = wibox({
        visible = false,
        ontop = true,
        -- When bg_image is set, the wibox itself must be transparent so that
        -- the widget's bgimage + overlay is what the user sees.
        bg = bg_image_surface and "#00000000" or config.bg_color,
        x = s.geometry.x,
        y = s.geometry.y,
        width = s.geometry.width,
        height = s.geometry.height,
        -- Two-layer: outer holds bgimage, inner child paints the overlay *on top*
        -- of it. (background renders bg before bgimage, so a single layer would
        -- put the overlay under the image — invisible.)
        -- The inner background has no child widget, so we force its size to
        -- the screen geometry; otherwise its :fit() returns 0x0 and the
        -- overlay paints a zero-size rectangle (i.e. doesn't dim anything).
        widget = bg_image_surface and wibox.widget({
            {
                forced_width  = s.geometry.width,
                forced_height = s.geometry.height,
                bg = config.bg_image_overlay,
                widget = wibox.container.background,
            },
            bgimage = bg_image_surface,
            widget = wibox.container.background,
        }) or nil,
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
        bg = config.bg_color,
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
    -- Fields where `false` is a meaningful value (disable) rather than
    -- "unset". Using `or` chaining would silently promote a theme's
    -- `lockscreen_bg_image_blur = true` over a user's explicit
    -- `opts.bg_image_blur = false`; resolve these with explicit nil checks.
    local falsey_valid = {
        bg_image       = true,
        bg_image_blur  = true,
        lock_screen    = true,
    }
    for k, default in pairs(defaults) do
        if falsey_valid[k] then
            if opts[k] ~= nil then
                config[k] = opts[k]
            elseif beautiful["lockscreen_" .. k] ~= nil then
                config[k] = beautiful["lockscreen_" .. k]
            else
                config[k] = default
            end
        else
            config[k] = (opts[k])
                or beautiful["lockscreen_" .. k]
                or (theme_fallbacks[k] and beautiful[theme_fallbacks[k]])
                or default
        end
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
