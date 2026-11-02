---------------------------------------------------------------------------
--- Querying the current GTK+ 3 theme colors.
--
-- Reads the `@define-color` declarations from the theme's CSS. AwesomeWM
-- creates GTK widgets instead, but GTK cannot start without a display, and
-- inside the compositor the display is the compositor itself, which is
-- blocked while rc.lua runs.
--
-- @themelib beautiful.gtk
---------------------------------------------------------------------------
local lgi = require("lgi")
local Gio, GLib = lgi.Gio, lgi.GLib
local gears_color = require("gears.color")
local gears_debug = require("gears.debug")
local gears_math = require("gears.math")
local unpack = unpack or table.unpack -- luacheck: globals unpack (compatibility with Lua 5.1)


local gtk = {
    cached_theme_variables = nil
}

-- GTK 3 compiles Adwaita into libgtk, where it can only be read after
-- gtk_init(). These are its colors from GTK 3.24, keyed by the resource path
-- GTK and on-disk themes such as Adwaita-dark load it from. Adwaita does not
-- define menubar_bg_color: it is Adwaita's compiled header bar background,
-- which AwesomeWM reads from a widget.
local builtin = {
    ["/org/gtk/libgtk/theme/Adwaita/gtk-contained.css"] = [[
        @define-color theme_fg_color #2e3436;
        @define-color theme_text_color black;
        @define-color theme_bg_color #f6f5f4;
        @define-color theme_base_color #ffffff;
        @define-color theme_selected_bg_color #3584e4;
        @define-color theme_selected_fg_color #ffffff;
        @define-color borders #cdc7c2;
        @define-color warning_color #f57900;
        @define-color error_color #cc0000;
        @define-color success_color #33d17a;
        @define-color menubar_bg_color #dfdcd8;
    ]],
    ["/org/gtk/libgtk/theme/Adwaita/gtk-contained-dark.css"] = [[
        @define-color theme_fg_color #eeeeec;
        @define-color theme_text_color white;
        @define-color theme_bg_color #353535;
        @define-color theme_base_color #2d2d2d;
        @define-color theme_selected_bg_color #15539e;
        @define-color theme_selected_fg_color #ffffff;
        @define-color borders #1b1b1b;
        @define-color warning_color #f57900;
        @define-color error_color #cc0000;
        @define-color success_color #26ab62;
        @define-color menubar_bg_color #1b1b1b;
    ]],
}

local function clamp(v)
    return math.min(math.max(v, 0), 1)
end

-- GTK's shade(): scales lightness and saturation in HSL.
local function shade(c, factor)
    local r, g, b = c[1], c[2], c[3]
    local max, min = math.max(r, g, b), math.min(r, g, b)
    local l, s, h = (max + min) / 2, 0, 0
    if max ~= min then
        local d = max - min
        s = l > 0.5 and d / (2 - max - min) or d / (max + min)
        if max == r then
            h = (g - b) / d + (g < b and 6 or 0)
        elseif max == g then
            h = (b - r) / d + 2
        else
            h = (r - g) / d + 4
        end
        h = h / 6
    end
    l, s = clamp(l * factor), clamp(s * factor)
    local q = l < 0.5 and l * (1 + s) or l + s - l * s
    local p = 2 * l - q
    local function channel(t)
        t = t % 1
        if t < 1/6 then return p + (q - p) * 6 * t end
        if t < 1/2 then return q end
        if t < 2/3 then return p + (q - p) * (2/3 - t) * 6 end
        return p
    end
    return {channel(h + 1/3), channel(h), channel(h - 1/3), c[4]}
end

local function split_args(s)
    local args, depth, start = {}, 0, 1
    for i = 1, #s do
        local ch = s:sub(i, i)
        if ch == "(" then
            depth = depth + 1
        elseif ch == ")" then
            depth = depth - 1
        elseif ch == "," and depth == 0 then
            table.insert(args, s:sub(start, i - 1))
            start = i + 1
        end
    end
    table.insert(args, s:sub(start))
    return args
end

local function rgb_channel(s)
    local n, percent = (s or ""):match("^%s*([%d.]+)(%%?)%s*$")
    n = tonumber(n)
    return n and (percent == "%" and n / 100 or n / 255)
end

-- Evaluate a GTK 3 color expression to {r, g, b, a}, or nil if it uses
-- syntax this reader does not know. `defs` maps names to expressions. A
-- resolved reference is stored back in `defs`, false while it resolves, so
-- each name is evaluated once and a cycle returns nil.
local function evaluate(expr, defs)
    expr = expr:match("^%s*(.-)%s*$")

    local ref = expr:match("^@([%w_-]+)$")
    if ref then
        local value = defs[ref]
        if type(value) == "string" then
            defs[ref] = false
            defs[ref] = evaluate(value, defs) or false
        end
        return defs[ref] or nil
    end

    if expr == "transparent" then
        return {0, 0, 0, 0}
    end

    local fn, inner = expr:match("^([%a-]+)%s*(%b())$")
    if not fn then
        local r, g, b, a = gears_color.parse_color(expr)
        return r and {r, g, b, a}
    end
    local args = split_args(inner:sub(2, -2))

    if fn == "rgb" or fn == "rgba" then
        local r, g, b = rgb_channel(args[1]), rgb_channel(args[2]), rgb_channel(args[3])
        local a = fn == "rgba" and tonumber(args[4]) or 1
        return r and g and b and {r, g, b, a}
    end

    local c, factor = evaluate(args[1], defs), tonumber(args[#args])
    if not c then
        return nil
    elseif fn == "lighter" then
        return shade(c, 1.3)
    elseif fn == "darker" then
        return shade(c, 0.7)
    elseif not factor then
        return nil
    elseif fn == "shade" then
        return shade(c, factor)
    elseif fn == "alpha" then
        return {c[1], c[2], c[3], clamp(c[4] * factor)}
    elseif fn == "mix" then
        local c2 = args[2] and evaluate(args[2], defs)
        if not c2 then
            return nil
        end
        local result = {}
        for i = 1, 4 do
            result[i] = clamp(c[i] + (c2[i] - c[i]) * factor)
        end
        return result
    end
end

-- Return a theme's CSS with its @import rules replaced by the imported text.
-- `resource` is the theme's gtk.gresource, if it ships one.
local function read_css(file, resource, depth)
    if depth > 8 then
        return ""
    end
    local text
    local path = file:get_uri():match("^resource://(/.*)$")
    if path then
        local bytes = resource and resource:lookup_data(path, 0)
        text = builtin[path] or (bytes and bytes:get_data())
    else
        text = file:load_contents()
    end
    if not text then
        return ""
    end
    text = text:gsub("/%*.-%*/", "")
    return (text:gsub("@import%s+url%(%s*[\"']?(.-)[\"']?%s*%)%s*;", function(target)
        local imported = target:match("^%a[%w+.-]*:")
            and Gio.File.new_for_uri(target)
            or file:get_parent():resolve_relative_path(target)
        return read_css(imported, resource, depth + 1)
    end))
end

-- Find a theme's CSS the way GTK 3 does: built-in themes first, then the
-- theme directories, newest gtk-3.N subdirectory first (GTK skips 3.1 to
-- 3.12). A missing variant
-- falls back to the plain theme, and a missing theme falls back to Adwaita.
local function load_theme(name, variant)
    local suffix = variant and ("-" .. variant) or ""
    local builtin_path = "/org/gtk/libgtk/theme/" .. name .. "/gtk-contained" .. suffix .. ".css"
    if builtin[builtin_path] then
        return builtin[builtin_path]
    end

    local home = os.getenv("HOME") or ""
    local dirs = {
        (os.getenv("XDG_DATA_HOME") or home .. "/.local/share") .. "/themes",
        home .. "/.themes",
    }
    for dir in (os.getenv("XDG_DATA_DIRS") or "/usr/local/share:/usr/share"):gmatch("[^:]+") do
        table.insert(dirs, dir .. "/themes")
    end

    for _, dir in ipairs(dirs) do
        for _, minor in ipairs({24, 22, 20, 18, 16, 14, 0}) do
            local theme_dir = dir .. "/" .. name .. "/gtk-3." .. minor .. "/"
            local file = Gio.File.new_for_path(theme_dir .. "gtk" .. suffix .. ".css")
            if file:query_exists() then
                return read_css(file, Gio.Resource.load(theme_dir .. "gtk.gresource"), 0)
            end
        end
    end

    return load_theme(variant and name or "Adwaita")
end

-- GTK 3 on Wayland takes the theme name and font from gsettings when the
-- schema is installed, and the dark preference only from settings.ini.
local function read_settings()
    local ini = GLib.KeyFile()
    local config = os.getenv("XDG_CONFIG_HOME") or (os.getenv("HOME") or "") .. "/.config"
    ini:load_from_file(config .. "/gtk-3.0/settings.ini", GLib.KeyFileFlags.NONE)

    local theme = ini:get_string("Settings", "gtk-theme-name")
    local font = ini:get_string("Settings", "gtk-font-name")
    local source = Gio.SettingsSchemaSource.get_default()
    if source and source:lookup("org.gnome.desktop.interface", true) then
        local settings = Gio.Settings.new("org.gnome.desktop.interface")
        theme, font = settings:get_string("gtk-theme"), settings:get_string("font-name")
    end

    local variant = ini:get_boolean("Settings", "gtk-application-prefer-dark-theme") and "dark" or nil

    local env_name, env_variant = (os.getenv("GTK_THEME") or ""):match("^([^:]+):?(.*)$")
    if env_name then
        theme, variant = env_name, env_variant ~= "" and env_variant or nil
    end

    return theme or "Adwaita", variant, font or "Sans 10"
end

local function to_hex(c)
    local hex = "#"
    for i = 1, 4 do
        hex = hex .. string.format("%02x", gears_math.round(c[i] * 255))
    end
    return hex
end

function gtk.get_theme_variables()
    if gtk.cached_theme_variables then
        return gtk.cached_theme_variables
    end

    local theme, variant, font = read_settings()
    local defs = {}
    for name, value in load_theme(theme, variant):gmatch("@define%-color%s+([%w_-]+)%s+([^;]+);") do
        defs[name] = value
    end
    local function lookup(name)
        local c = evaluate("@" .. name, defs)
        return c and to_hex(c)
    end

    -- AwesomeWM reads these from the style of real widgets. Without widgets,
    -- the button and header button borders use the theme's `borders` color,
    -- and the radius and width are Adwaita's.
    local family, size = font:match("^(.-),?%s+([%d.]+)$")
    local borders = lookup("borders")
    local result = {
        font_family = family or font,
        font_size = tonumber(size) or 10,
        button_border_color = borders,
        header_button_border_color = borders,
        button_border_radius = 5,
        button_border_width = 1,
    }

    -- AwesomeWM's lookup table: the GTK color name, then result keys to fall
    -- back on when the theme does not define it.
    for _, color_data in ipairs({
        {"bg_color", "theme_bg_color"},
        {"fg_color", "theme_fg_color"},
        {"base_color", "theme_base_color"},
        {"text_color", "theme_text_color"},
        {"selected_bg_color", "theme_selected_bg_color"},
        {"selected_fg_color", "theme_selected_fg_color"},
        --
        {"tooltip_bg_color", "theme_tooltip_bg_color", "bg_color"},
        {"tooltip_fg_color", "theme_tooltip_fg_color", "fg_color"},
        {"osd_bg_color", "osd_bg", "tooltip_bg_color"},
        {"osd_fg_color", "osd_fg", "tooltip_fg_color"},
        {"osd_border_color", "osd_borders_color", "osd_fg_color"},
        {"menubar_bg_color", "menubar_bg_color", "bg_color"},
        {"menubar_fg_color", "menubar_fg_color", "fg_color"},
        --
        {"button_bg_color", "button_bg_color", "bg_color"},
        {"button_fg_color", "button_fg_color", "fg_color"},
        {"header_button_bg_color", "header_button_bg_color", "menubar_bg_color"},
        {"header_button_fg_color", "header_button_fg_color", "menubar_fg_color"},
        --
        {"wm_bg_color", "wm_bg", "menubar_bg_color"},
        {"wm_border_focused_color", "wm_border_focused", "selected_bg_color"},
        {"wm_border_unfocused_color", "wm_border_unfocused", "wm_border", "menubar_bg_color"},
        {"wm_title_focused_color", "wm_title_focused", "wm_title", "selected_fg_color"},
        {"wm_title_unfocused_color", "wm_title_unfocused", "wm_unfocused_title", "menubar_fg_color"},
        {"wm_icons_focused_color", "wm_icons_focused", "wm_title_focused_color", "selected_fg_color"},
        {"wm_icons_unfocused_color", "wm_icons_unfocused", "wm_title_unfocused_color", "menubar_fg_color"},
        --
        {"error_color", "error_color"},
        {"error_bg_color", "error_bg_color", "error_color"},
        {"error_fg_color", "error_fg_color", "selected_fg_color"},
        {"error_color", "error_color", "error_bg_color"},
        {"warning_color", "warning_color"},
        {"warning_bg_color", "warning_bg_color", "warning_color"},
        {"warning_fg_color", "warning_fg_color", "selected_fg_color"},
        {"warning_color", "warning_color", "warning_bg_color"},
        {"success_color", "success_color"},
        {"success_bg_color", "success_bg_color", "success_color"},
        {"success_fg_color", "success_fg_color", "selected_fg_color"},
        {"success_color", "success_color", "success_bg_color"},
    }) do
        local result_key, gtk_name, fallback_key, fallback_key2 = unpack(color_data)
        result[result_key] = lookup(gtk_name) or result[fallback_key] or result[fallback_key2]
        if not result[result_key] then
            gears_debug.print_warning("Can't read color '" .. gtk_name .. "' from GTK+3 theme.")
        end
    end

    gtk.cached_theme_variables = result
    return result
end


return gtk
