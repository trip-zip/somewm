--- Xresources parser for Wayland compatibility
-- This module provides xrdb functionality without requiring X11
-- @module gears.xresources

local xresources = {}

-- Cache for parsed values
local cache = {}
local loaded = false

-- Default values for common xrdb properties
-- These provide a sensible dark theme when .Xresources is not available
local defaults = {
  -- Terminal colors - Catppuccin Mocha theme
  background = "#1e1e2e",
  foreground = "#cdd6f4",
  -- Black/Bright Black
  color0 = "#45475a",
  color8 = "#585b70",
  -- Red/Bright Red
  color1 = "#f38ba8",
  color9 = "#f38ba8",
  -- Green/Bright Green
  color2 = "#a6e3a1",
  color10 = "#a6e3a1",
  -- Yellow/Bright Yellow
  color3 = "#f9e2af",
  color11 = "#f9e2af",
  -- Blue/Bright Blue
  color4 = "#89b4fa",
  color12 = "#89b4fa",
  -- Magenta/Bright Magenta
  color5 = "#f5c2e7",
  color13 = "#f5c2e7",
  -- Cyan/Bright Cyan
  color6 = "#94e2d5",
  color14 = "#94e2d5",
  -- White/Bright White
  color7 = "#bac2de",
  color15 = "#a6adc8",
  -- DPI setting
  ["Xft.dpi"] = "96",
  -- Font settings
  ["Xft.antialias"] = "1",
  ["Xft.hinting"] = "1",
  ["Xft.rgba"] = "rgb",
  ["Xft.hintstyle"] = "hintslight",
}

--- Parse .Xresources file
-- @local
local function parse_xresources_file()
  if loaded then
    return
  end
  loaded = true

  local home = os.getenv("HOME")
  if not home then
    return
  end

  -- Try .Xresources first, then .Xdefaults
  local paths = {
    home .. "/.Xresources",
    home .. "/.Xdefaults",
  }

  local file = nil
  for _, path in ipairs(paths) do
    file = io.open(path, "r")
    if file then
      break
    end
  end

  if not file then
    return
  end

  -- Parse the file line by line
  for line in file:lines() do
    -- Skip comments and empty lines
    if not line:match("^[!#]") and line:match("%S") then
      -- Match key:value pairs (with optional * prefix)
      local key, value = line:match("^%*?([^:]+):%s*(.+)%s*$")
      if key and value then
        -- Trim whitespace
        key = key:gsub("^%s*(.-)%s*$", "%1")
        value = value:gsub("^%s*(.-)%s*$", "%1")
        cache[key] = value
      end
    end
  end

  file:close()
end

--- Get an xresource value
-- @param resource_class Resource class (usually empty string or nil)
-- @param resource_name Resource name (e.g., "background", "Xft.dpi")
-- @return Resource value string or nil if not found
function xresources.get_value(resource_class, resource_name)
  -- Ensure we've tried to load the file
  parse_xresources_file()

  local value = nil

  -- Try with class prefix if provided
  if resource_class and resource_class ~= "" then
    value = cache[resource_class .. "." .. resource_name]
  end

  -- Try just the resource name
  if not value then
    value = cache[resource_name]
  end

  -- Try environment variable fallback
  if not value then
    local env_name = "SOMEWM_" .. resource_name:gsub("%.", "_")
    value = os.getenv(env_name)
  end

  -- Try built-in defaults
  if not value then
    value = defaults[resource_name]
  end

  return value
end

--- Get all xresource color values (color0-15, background, foreground)
-- @return Table of color values
function xresources.get_colors()
  local colors = {}

  -- Get background and foreground
  colors.background = xresources.get_value("", "background")
  colors.foreground = xresources.get_value("", "foreground")

  -- Get color0-15
  for i = 0, 15 do
    colors["color" .. i] = xresources.get_value("", "color" .. i)
  end

  return colors
end

--- Get DPI value from xresources
-- @return DPI value as number (defaults to 96)
function xresources.get_dpi()
  local dpi = xresources.get_value("", "Xft.dpi")
  return tonumber(dpi) or 96
end

--- Apply xresource theme to beautiful
-- @param beautiful The beautiful module
function xresources.apply_theme(beautiful)
  local colors = xresources.get_colors()

  -- Apply colors to beautiful theme
  beautiful.bg_normal = colors.background
  beautiful.fg_normal = colors.foreground
  beautiful.bg_focus = colors.color4 -- Use blue for focus
  beautiful.fg_focus = colors.foreground
  beautiful.bg_urgent = colors.color1 -- Use red for urgent
  beautiful.fg_urgent = colors.foreground

  -- Apply DPI
  beautiful.xresources_dpi = xresources.get_dpi()

  return colors
end

return xresources
