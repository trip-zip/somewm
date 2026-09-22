---------------------------------------------------------------------------
-- Replicate the content of the widget over and over.
--
-- This contained is intended to be used for wallpapers. It currently doesn't
-- support mouse input in the replicated tiles.
--
--@DOC_wibox_container_defaults_tile_EXAMPLE@
-- @author Emmanuel Lepage-Vallee
-- @copyright 2021 Emmanuel Lepage-Vallee
-- @containermod wibox.container.tile
-- @supermodule wibox.container.place
local place = require("wibox.container.place")
local gtable = require("gears.table")

local module = {mt = {}}


--- The horizontal spacing between the tiled.
--
--@DOC_wibox_container_tile_horizontal_spacing_EXAMPLE@
--
-- @property horizontal_spacing
-- @tparam[opt=0] number horizontal_spacing
-- @propemits true false
-- @propertyunit pixel
-- @negativeallowed false
-- @see vertical_spacing

--- The vertical spacing between the tiled.
--
--@DOC_wibox_container_tile_vertical_spacing_EXAMPLE@
--
-- @property vertical_spacing
-- @tparam[opt=0] number vertical_spacing
-- @propertyunit pixel
-- @negativeallowed false
-- @propemits true false
-- @see horizontal_spacing

--- Avoid painting incomplete horizontal tiles.
--
--@DOC_wibox_container_tile_horizontal_crop_EXAMPLE@
--
-- @property horizontal_crop
-- @tparam[opt=false] boolean horizontal_crop
-- @see vertical_crop

--- Avoid painting incomplete vertical tiles.
--
--@DOC_wibox_container_tile_vertical_crop_EXAMPLE@
--
-- @property vertical_crop
-- @tparam[opt=false] boolean vertical_crop
-- @see horizontal_crop

--- Enable or disable the tiling.
--
-- When set to `false`, this container behaves exactly like
-- `wibox.container.place`.
--
--@DOC_wibox_container_tile_tiled_EXAMPLE@
--
-- @property tiled
-- @tparam[opt=true] boolean tiled

local defaults = {
    horizontal_spacing = 0,
    vertical_spacing   = 0,
    tiled              = true,
    horizontal_crop    = false,
    vertical_crop      = false,
}

for prop in pairs(defaults) do

    module["set_"..prop] = function(self, value)
        self._private[prop] = value
        self:emit_signal("widget::redraw_needed", value)
    end

    module["get_"..prop] = function(self)
        if self._private[prop] == nil then
            return defaults[prop]
        end

        return self._private[prop]
    end
end

local function new(_, args)
    args = args or {}
    local ret = place(args.widget, args.halign, args.valign)
    gtable.crush(ret, module, true)
    ret._private.tiled = true

    local function redraw()
        ret:emit_signal("widget::redraw_needed")
    end

    -- Resize the pattern as needed.
    local function reset()
        if ret._private.surface then
            ret._private.surface:finish()
        end

        ret._private.cr = nil
        ret._private.surface = nil
        ret._private.pattern = nil
    end

    local w = nil

    ret:connect_signal("property::widget", function()
        reset()

        if w then
            w:disconnect_signal("widget::redraw_needed", redraw)
            w:disconnect_signal("widget::layout_changed", reset)
        end

        w = ret._private.widget

        if w then
            w:connect_signal("widget::redraw_needed", redraw)
            w:connect_signal("widget::layout_changed", reset)
        end
    end)

    return ret
end

--- Create a new tile container.
-- @tparam table args
-- @tparam wibox.widget args.widget args.widget The widget to tile.
-- @tparam string args.halign Either `left`, `right` or `center`.
-- @tparam string args.valign Either `top`, `bottom` or `center`.
-- @tparam number args.horizontal_spacing The horizontal spacing between the tiled.
-- @tparam number args.vertical_spacing The vertical spacing between the tiled.
-- @tparam boolean args.horizontal_crop Avoid painting incomplete horizontal tiles.
-- @tparam boolean args.vertical_crop Avoid painting incomplete vertical tiles.
-- @tparam boolean args.tiled Enable or disable the tiling.
-- @tparam wibox.widget args.widget The widget to be placed.
-- @tparam boolean args.fill_vertical Fill the vertical space.
-- @tparam boolean args.fill_horizontal Fill the horizontal space.
-- @tparam boolean args.content_fill_vertical Stretch the contained widget so it takes all the vertical space.
-- @tparam boolean args.content_fill_horizontal Stretch the contained widget so it takes all the horizontal space.
-- @constructorfct wibox.container.tile
function module.mt:__call(...)
    return new(...)
end

return setmetatable(module, module.mt)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
