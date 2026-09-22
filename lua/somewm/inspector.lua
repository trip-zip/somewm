---------------------------------------------------------------------------
--- Clay's debug inspector over the desktop.
--
-- Clay draws its own inspector panel inside the solve when a screen's flag
-- is on (third_party/clay.h, Clay__RenderDebugView): the screen's element
-- tree row by row, and the solved box and configuration of the selected
-- one. `screen.inspector` is the flag, per screen; the panel's colors,
-- width and font come from beautiful and are process-wide, so every open
-- panel shares them.
--
-- Usage in rc.lua:
--     awful.key {
--         modifiers = { modkey, "Shift" }, key = "i",
--         on_press  = function() require("somewm.inspector").toggle() end,
--     }
--
-- @module somewm.inspector
---------------------------------------------------------------------------

local capi = { awesome = awesome }
local beautiful = require("beautiful")
local gcolor = require("gears.color")
local gdebug = require("gears.debug")
local ascreen = require("awful.screen")
local Pango = require("lgi").Pango

local inspector = {}

--- The panel body and its odd rows.
-- @beautiful beautiful.inspector_bg
-- @tparam[opt="#3a3834"] color inspector_bg

--- The header, the even rows, and the info and warnings panes.
-- @beautiful beautiful.inspector_bg_alt
-- @tparam[opt="#3e3c3a"] color inspector_bg_alt

--- Dividers, row borders and dim text (ids, the Offscreen tag).
-- @beautiful beautiful.inspector_border
-- @tparam[opt="#8d8587"] color inspector_border

--- Text and swatch borders.
-- @beautiful beautiful.inspector_fg
-- @tparam[opt="#eee2e7"] color inspector_fg

--- The selected tree row.
-- @beautiful beautiful.inspector_bg_selected
-- @tparam[opt="#66504e"] color inspector_bg_selected

--- The overlay drawn over the hovered element out on the desktop. Its
-- alpha shows the element through.
-- @beautiful beautiful.inspector_highlight
-- @tparam[opt="#a8421c64"] color inspector_highlight

--- The panel width in logical pixels.
-- @beautiful beautiful.inspector_width
-- @tparam[opt=400] number inspector_width

--- The panel font. A size, absolute (`"Monospace 14px"`) or in points
-- (`"Monospace 10"`), sizes the panel's text; without one Clay's 16px
-- stands. Rows are 30px, so sizes past about 20px overflow them.
-- @beautiful beautiful.inspector_font
-- @tparam[opt="Sans"] string inspector_font

local defaults = {
    inspector_bg = "#3a3834",
    inspector_bg_alt = "#3e3c3a",
    inspector_border = "#8d8587",
    inspector_fg = "#eee2e7",
    inspector_bg_selected = "#66504e",
    inspector_highlight = "#a8421c64",
}

-- A theme color as {r, g, b, a} in 0-255. A pattern that is not one solid
-- color falls back to the default with a warning.
local function rgba(name)
    local value = beautiful[name]
    local pattern = value and gcolor(value)

    if not pattern or pattern:get_type() ~= "SOLID" then
        if value then
            gdebug.print_warning("beautiful." .. name
                .. " is not a solid color, using " .. defaults[name])
        end
        pattern = gcolor(defaults[name])
    end

    local _, r, g, b, a = pattern:get_rgba()

    return { r * 255, g * 255, b * 255, a * 255 }
end

-- The panel font as a description whose size, if any, is absolute: the
-- converted textbox's rule, at the theme's dpi.
local function font()
    local desc = beautiful.get_font(beautiful.inspector_font or "Sans"):copy()
    local size = desc:get_size() / Pango.SCALE

    if size > 0 and not desc:get_size_is_absolute() then
        desc:set_absolute_size(
            size * beautiful.xresources.get_dpi() / 72 * Pango.SCALE)
    end
    return desc:to_string()
end

--- Re-read the theme and apply it to every open panel.
--
-- Enabling a screen's inspector does this first, so it is only needed
-- after the theme changes at runtime.
--
-- @staticfct somewm.inspector.restyle
function inspector.restyle()
    local err = capi.awesome._inspector_style {
        bg = rgba("inspector_bg"),
        bg_alt = rgba("inspector_bg_alt"),
        border = rgba("inspector_border"),
        fg = rgba("inspector_fg"),
        bg_selected = rgba("inspector_bg_selected"),
        highlight = rgba("inspector_highlight"),
        width = tonumber(beautiful.inspector_width) or 400,
        font = font(),
    }

    if err then
        gdebug.print_warning("beautiful.inspector_font " .. err)
    end
end

--- Toggle the inspector on a screen.
--
-- @tparam[opt=awful.screen.focused()] screen s The screen.
-- @treturn boolean Whether the panel is now up.
-- @staticfct somewm.inspector.toggle
function inspector.toggle(s)
    s = s or ascreen.focused()
    s.inspector = not s.inspector
    return s.inspector
end

return inspector

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
