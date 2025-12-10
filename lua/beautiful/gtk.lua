---------------------------------------------------------------------------
--- Wayland-safe GTK theme variable provider.
-- This module provides GTK theme colors without creating GTK windows,
-- making it safe to use during Wayland compositor startup.
--
-- It follows the same pattern as gears/xresources.lua:
-- 1. Try to read from local config files
-- 2. Fall back to environment variables
-- 3. Fall back to sensible defaults
--
-- @author somewm contributors
-- @themelib beautiful.gtk
---------------------------------------------------------------------------
local gears_debug = require("gears.debug")

local gtk = {
    cached_theme_variables = nil
}

-- Default GTK theme colors (Adwaita Dark)
-- These provide a sensible dark theme when GTK config is not available
local defaults = {
    -- Core colors
    bg_color = "#353535ff",
    fg_color = "#eeeeecff",
    base_color = "#2d2d2dff",
    text_color = "#eeeeecff",
    selected_bg_color = "#215d9cff",
    selected_fg_color = "#ffffffff",

    -- Button colors
    button_bg_color = "#444444ff",
    button_fg_color = "#eeeeecff",
    button_border_color = "#1c1c1cff",
    button_border_radius = 5,
    button_border_width = 1,

    -- Header button colors
    header_button_bg_color = "#444444ff",
    header_button_fg_color = "#eeeeecff",
    header_button_border_color = "#1c1c1cff",

    -- Menubar colors
    menubar_bg_color = "#353535ff",
    menubar_fg_color = "#eeeeecff",

    -- Tooltip colors
    tooltip_bg_color = "#353535ff",
    tooltip_fg_color = "#eeeeecff",

    -- OSD colors
    osd_bg_color = "#353535ff",
    osd_fg_color = "#eeeeecff",
    osd_border_color = "#eeeeecff",

    -- Window manager colors
    wm_bg_color = "#353535ff",
    wm_border_focused_color = "#215d9cff",
    wm_border_unfocused_color = "#353535ff",
    wm_title_focused_color = "#ffffffff",
    wm_title_unfocused_color = "#eeeeecff",
    wm_icons_focused_color = "#ffffffff",
    wm_icons_unfocused_color = "#eeeeecff",

    -- Status colors
    error_color = "#cc0000ff",
    error_bg_color = "#cc0000ff",
    error_fg_color = "#ffffffff",
    warning_color = "#f57900ff",
    warning_bg_color = "#f57900ff",
    warning_fg_color = "#ffffffff",
    success_color = "#4e9a06ff",
    success_bg_color = "#4e9a06ff",
    success_fg_color = "#ffffffff",

    -- Font settings
    font_family = "Sans",
    font_size = 10,
}

--- Parse a GTK settings.ini file
-- @param path Path to settings.ini file
-- @return Table of parsed settings or nil
local function parse_gtk_settings_ini(path)
    local file = io.open(path, "r")
    if not file then
        return nil
    end

    local settings = {}
    for line in file:lines() do
        -- Skip comments and section headers
        if not line:match("^[#;%[]") and line:match("%S") then
            local key, value = line:match("^%s*([^=]+)%s*=%s*(.+)%s*$")
            if key and value then
                settings[key:gsub("^%s*(.-)%s*$", "%1")] = value:gsub("^%s*(.-)%s*$", "%1")
            end
        end
    end
    file:close()
    return settings
end

--- Try to get GTK theme name from gsettings
-- @return Theme name string or nil
local function get_gtk_theme_from_gsettings()
    local handle = io.popen("gsettings get org.gnome.desktop.interface gtk-theme 2>/dev/null")
    if not handle then
        return nil
    end
    local result = handle:read("*a")
    handle:close()
    if result then
        -- Remove quotes and whitespace
        result = result:gsub("^%s*'?", ""):gsub("'?%s*$", "")
        if result ~= "" then
            return result
        end
    end
    return nil
end

--- Try to detect if the theme is a dark theme
-- @param theme_name GTK theme name
-- @return true if dark theme, false otherwise
local function is_dark_theme(theme_name)
    if not theme_name then
        return true  -- Default to dark
    end
    local name_lower = theme_name:lower()
    return name_lower:match("dark") ~= nil or
           name_lower:match("night") ~= nil or
           name_lower:match("black") ~= nil
end

--- Get GTK theme variables
-- This function provides GTK theme colors without creating GTK windows.
-- Safe to call during Wayland compositor startup.
-- @return Table of theme variables
function gtk.get_theme_variables()
    if gtk.cached_theme_variables then
        return gtk.cached_theme_variables
    end

    local result = {}

    -- Copy defaults first
    for k, v in pairs(defaults) do
        result[k] = v
    end

    -- Try to read user's GTK settings
    local home = os.getenv("HOME")
    if home then
        -- Try GTK 3 settings
        local gtk3_settings = parse_gtk_settings_ini(home .. "/.config/gtk-3.0/settings.ini")
        if gtk3_settings then
            -- Extract theme name if available
            local theme_name = gtk3_settings["gtk-theme-name"]
            if theme_name then
                gears_debug.print_warning("beautiful.gtk: Found GTK theme: " .. theme_name)
            end

            -- Extract font if available
            if gtk3_settings["gtk-font-name"] then
                local font = gtk3_settings["gtk-font-name"]
                local family, size = font:match("^(.+)%s+(%d+)$")
                if family and size then
                    result.font_family = family
                    result.font_size = tonumber(size) or 10
                end
            end
        end
    end

    -- Try gsettings for theme name
    local gsettings_theme = get_gtk_theme_from_gsettings()
    if gsettings_theme then
        -- Adjust colors based on light/dark theme
        if not is_dark_theme(gsettings_theme) then
            -- Light theme colors (Adwaita Light)
            result.bg_color = "#f6f5f4ff"
            result.fg_color = "#2e3436ff"
            result.base_color = "#ffffffff"
            result.text_color = "#2e3436ff"
            result.button_bg_color = "#e8e8e7ff"
            result.button_fg_color = "#2e3436ff"
            result.menubar_bg_color = "#f6f5f4ff"
            result.menubar_fg_color = "#2e3436ff"
            result.tooltip_bg_color = "#f6f5f4ff"
            result.tooltip_fg_color = "#2e3436ff"
            result.osd_bg_color = "#f6f5f4ff"
            result.osd_fg_color = "#2e3436ff"
            result.wm_bg_color = "#f6f5f4ff"
            result.wm_title_focused_color = "#2e3436ff"
            result.wm_title_unfocused_color = "#929595ff"
        end
    end

    -- Allow environment variable overrides (SOMEWM_GTK_*)
    local env_overrides = {
        "bg_color", "fg_color", "base_color", "text_color",
        "selected_bg_color", "selected_fg_color",
        "button_bg_color", "button_fg_color",
        "menubar_bg_color", "menubar_fg_color",
    }
    for _, key in ipairs(env_overrides) do
        local env_name = "SOMEWM_GTK_" .. key:upper()
        local env_value = os.getenv(env_name)
        if env_value then
            result[key] = env_value
        end
    end

    gtk.cached_theme_variables = result
    return result
end


return gtk
