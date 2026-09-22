---------------------------------------------------------------------------
-- A flexible separator widget.
--
-- By default, this widget displays a simple line, but can be extended by themes
-- (or directly) to display much more complex visuals.
--
-- This widget is mainly intended to be used alongside the `spacing_widget`
-- property supported by various layouts such as:
--
-- * `wibox.layout.fixed`
-- * `wibox.layout.flex`
-- * `wibox.layout.ratio`
--
-- When used with these layouts, it is also possible to provide custom clipping
-- functions. This is useful when the layout has overlapping widgets (negative
-- spacing).
--
--@DOC_wibox_widget_defaults_separator_EXAMPLE@
--
-- @author Emmanuel Lepage Vallee &lt;elv1313@gmail.com&gt;
-- @copyright 2014, 2017 Emmanuel Lepage Vallee
-- @widgetmod wibox.widget.separator
-- @supermodule wibox.widget.base
---------------------------------------------------------------------------
local beautiful = require( "beautiful"         )
local base      = require( "wibox.widget.base" )
local gtable    = require( "gears.table"       )

local gshape = require("gears.shape")
local clay = require("wibox.clay")

local separator = {}

--- The separator's orientation.
--
-- The default value is selected automatically. If the widget is taller than
-- large, it will use vertical and vice versa.
--
--@DOC_wibox_widget_separator_orientation_EXAMPLE@
--
-- @property orientation
-- @tparam[opt="auto"] string orientation
-- @propertyvalue "vertical" From top to bottom.
-- @propertyvalue "horizontal" From left to right.
-- @propertyvalue "auto" Decide depending on the widget geometry.
-- @propemits true false

--- The separator's thickness.
--
-- This is used by the default line separator, but ignored when a shape is used.
--
-- @property thickness
-- @tparam number|nil thickness
-- @propertyunit pixel
-- @negativeallowed false
-- @propbeautiful
-- @propemits true false

--- The separator's shape.
--
--@DOC_wibox_widget_separator_shape_EXAMPLE@
--
-- @property shape
-- @tparam shape|nil shape A valid shape function
-- @propbeautiful
-- @propemits true false
-- @see gears.shape

--- The relative percentage covered by the bar.
--
-- @property span_ratio
-- @tparam[opt=1] number|nil span_ratio
-- @rangestart 0.0
-- @rangestop 1.0
-- @propertyunit A gradient between "small" (0.0) and "full width/height" (1.0).
-- @propbeautiful
-- @propemits true false

--- The separator's color.
-- @property color
-- @tparam color|nil color
-- @propbeautiful
-- @propemits true false
-- @see gears.color

--- The separator's border color.
--
--@DOC_wibox_widget_separator_border_color_EXAMPLE@
--
-- @property border_color
-- @tparam color|nil border_color
-- @propbeautiful
-- @propemits true false
-- @see gears.color

--- The separator's border width.
-- @property border_width
-- @tparam number|nil border_width
-- @propertyunit pixel
-- @negativeallowed false
-- @propbeautiful
-- @propemits true false

--- The separator thickness.
-- @beautiful beautiful.separator_thickness
-- @tparam[opt=1] number separator_thickness
-- @see thickness

--- The separator border color.
-- @beautiful beautiful.separator_border_color
-- @param color
-- @see border_color

--- The separator border width.
-- @beautiful beautiful.separator_border_width
-- @tparam[opt=0] number separator_border_width
-- @see border_width

--- The relative percentage covered by the bar.
-- @beautiful beautiful.separator_span_ratio
-- @tparam[opt=1] number separator_span_ratio A number between 0 and 1.

--- The separator's color.
-- @beautiful beautiful.separator_color
-- @param color
-- @see gears.color

--- The separator's shape.
--
-- @beautiful beautiful.separator_shape
-- @tparam[opt=gears.shape.rectangle] shape shape A valid shape function
-- @see gears.shape





local function describe_separator(w)
    local p = w._private
    local s = p.shape or beautiful.separator_shape
    if p.draw or beautiful.separator_draw then
        clay.ignore(w, "draw", "is not applied")
    end
    local col = p.color or beautiful.separator_color
    local fill = clay.solid_rgba(col)
    if col and not fill then
        clay.ignore(w, "color", "is not solid and is transparent")
        fill = { 0, 0, 0, 0 }
    end
    fill = fill or { 0, 0, 0, 1 }
    if not s then
        local thickness = p.thickness or beautiful.separator_thickness or 1
        local orientation = p.orientation
        -- Clay rejects percentages over 1 (third_party/clay.h:2030-2033).
        local span_ratio = math.max(0, math.min(1, w.span_ratio or 1))
        local child
        if orientation == "horizontal" then
            child = { w = { percent = span_ratio }, h = thickness, bg = fill }
        elseif orientation == "vertical" then
            child = { w = thickness, h = { percent = span_ratio }, bg = fill }
        else
            child = { w = "grow", h = "grow", fill = fill,
                shape = function(width, height)
                    if width > height then
                        local lw = width * span_ratio
                        return clay.shape_ops(gshape.rectangle, lw, thickness,
                            (width - lw) / 2, height / 2 - thickness / 2)
                    end
                    local lh = height * span_ratio
                    return clay.shape_ops(gshape.rectangle, thickness, lh,
                        width / 2 - thickness / 2, (height - lh) / 2)
                end }
        end
        -- Percent contributes no fit content (third_party/clay.h:2273),
        -- and uses the parent's size minus padding and gaps (:2292-2293).
        return { w = "grow", h = "grow", align = { x = "center", y = "center" },
            specs = { child } }
    end
    local bw = p.border_width or beautiful.separator_border_width or 0
    local bc = p.border_color or beautiful.separator_border_color
    local stroke
    if bw > 0 then
        if bc then
            stroke = clay.solid_rgba(bc)
            if not stroke then
                clay.ignore(w, "border_color", "is not solid and is transparent")
            end
        else
            fill = nil
        end
    end
    return { w = "grow", h = "grow", specs = {
        { w = "grow", h = "grow", fill = fill, stroke = stroke, stroke_width = bw,
            shape = function(width, height)
                return clay.shape_ops(s, width - bw, height - bw, bw / 2, bw / 2)
            end },
    } }
end

separator._clay = { describe = describe_separator }

for _, prop in ipairs {"orientation", "color", "thickness", "span_ratio",
                       "border_width", "border_color", "shape" } do
    separator["set_"..prop] = function(self, value)
        self._private[prop] = value
        self:emit_signal("property::"..prop, value)
        self:emit_signal("widget::redraw_needed")
    end
    separator["get_"..prop] = function(self)
        return self._private[prop] or beautiful["separator_"..prop]
    end
end

--- Create a new separator.
-- @constructorfct wibox.widget.separator
-- @tparam table args The arguments (all properties are available).
-- @tparam[opt] string args.orientation The separator's orientation.
-- @tparam[opt] number args.thickness The separator's thickness.
-- @tparam[opt] function args.shape The separator's shape.
-- @tparam[opt] number args.span_ratio The relative percentage covered by the bar.
-- @tparam[opt] color args.color The separator's color.
-- @tparam[opt] color args.border_color The separator's border color.
-- @tparam[opt] number args.border_width The separator's border width.

local function new(args)
    local ret = base.make_widget(nil, nil, {
        enable_properties = true,
    })
    gtable.crush(ret, separator, true)
    gtable.crush(ret, args or {})
    ret._private.orientation = ret._private.orientation or "auto"
    return ret
end

return setmetatable(separator, { __call = function(_, ...) return new(...) end })
-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
