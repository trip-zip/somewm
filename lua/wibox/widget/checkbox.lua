---------------------------------------------------------------------------
-- A boolean display widget.
--
-- If necessary, themes can implement custom shape:
--
--@DOC_wibox_widget_checkbox_custom_EXAMPLE@
--
--@DOC_wibox_widget_defaults_checkbox_EXAMPLE@
-- @author Emmanuel Lepage Valle
-- @copyright 2010 Emmanuel Lepage Vallee
-- @widgetmod wibox.widget.checkbox
-- @supermodule wibox.widget.base
---------------------------------------------------------------------------

local color     = require( "gears.color"       )
local base      = require( "wibox.widget.base" )
local beautiful = require( "beautiful"         )
local shape     = require( "gears.shape"       )
local gtable    = require( "gears.table"       )
local clay      = require( "wibox.clay"        )

local checkbox = {}

--- The outer (unchecked area) border width.
--
-- @beautiful beautiful.checkbox_border_width
-- @param number

--- The outer (unchecked area) background color, pattern or gradient.
--
-- @beautiful beautiful.checkbox_bg
-- @param color

--- The outer (unchecked area) border color.
--
-- @beautiful beautiful.checkbox_border_color
-- @param color

--- The checked part filling color.
--
-- @beautiful beautiful.checkbox_check_color
-- @param number

--- The outer (unchecked area) shape.
--
-- @beautiful beautiful.checkbox_shape
-- @tparam gears.shape|function shape
-- @see gears.shape

--- The padding between the outline and the progressbar.
--
-- @beautiful beautiful.checkbox_paddings
-- @tparam[opt=0] table|number paddings A number or a table
-- @tparam[opt=0] number paddings.top
-- @tparam[opt=0] number paddings.bottom
-- @tparam[opt=0] number paddings.left
-- @tparam[opt=0] number paddings.right

--- The checkbox color.
--
-- This will be used for the unchecked part border color and the checked part
-- filling color. Note that `check_color` and `border_color` have priority
-- over this property.
-- @beautiful beautiful.checkbox_color
-- @param color

--- The outer (unchecked area) border width.
--
-- @property border_width
-- @tparam number|nil border_width
-- @negativeallowed false
-- @propertyunit pixel
-- @propbeautiful
-- @propemits true false

--- The outer (unchecked area) background color, pattern or gradient.
--
--@DOC_wibox_widget_checkbox_bg_EXAMPLE@
-- @property bg
-- @tparam color|nil bg
-- @propbeautiful
-- @propemits true false

--- The outer (unchecked area) border color.
--
-- @property border_color
-- @tparam color|nil border_color
-- @propbeautiful
-- @propemits true false

--- The checked part filling color.
--
-- @property check_color
-- @tparam color|nil check_color
-- @propbeautiful
-- @propemits true false

--- The outer (unchecked area) shape.
--
--@DOC_wibox_widget_checkbox_shape_EXAMPLE@
-- @property shape
-- @tparam shape|nil shape
-- @propbeautiful
-- @propemits true false
-- @see gears.shape

--- The padding between the outline and the progressbar.
--
-- @property paddings
-- @tparam[opt=0] table|number|nil paddings A number or a table
-- @tparam[opt=0] number paddings.top
-- @tparam[opt=0] number paddings.bottom
-- @tparam[opt=0] number paddings.left
-- @tparam[opt=0] number paddings.right
-- @propertyunit pixel
-- @negativeallowed true
-- @propertytype number A single number for all sides.
-- @propertytype table A different value for each sides:
-- @propbeautiful
-- @propemits false false

--- The checkbox color.
--
-- This will be used for the unchecked part border color and the checked part
-- filling color. Note that `check_color` and `border_color` have priority
-- over this property.
-- @property color
-- @tparam color|nil color
-- @propbeautiful
-- @propemits true false

local function outline_workarea(self, width, height)
    local offset = (self._private.border_width or
        beautiful.checkbox_border_width or 1)/2

    return {
        x      = offset,
        y      = offset,
        width  = width-2*offset,
        height = height-2*offset
    }
end

-- The child widget area
local function content_workarea(self, width, height)
    local padding = self._private.paddings or {}
    local wa = outline_workarea(self, width, height)

    wa.x      = wa.x + (padding.left or 1)
    wa.y      = wa.y + (padding.top  or 1)
    wa.width  = wa.width  - (padding.left or 1) - (padding.right  or 1)
    wa.height = wa.height - (padding.top  or 1) - (padding.bottom or 1)

    return wa
end



local function describe_checkbox(w, fg, st, item, bound)
    local side, src = clay.square_side(w, bound)
    if not side then
        return clay.refuse(w, "size", "has no definite axis; force a size or put it in a sized host")
    end

    local main_color = w:get_color()
    local bg = w:get_bg()
    local border_color = w:get_border_color()
    local check_color = w:get_check_color()
    -- A gradient starts where `draw` set it: at each work area's corner.
    local outline_wa, content_wa = outline_workarea(w, side, side), content_workarea(w, side, side)
    local main = clay.solid_rgba(main_color)
    local main_fill = clay.fill(main_color, content_wa.x, content_wa.y)
    local background = clay.fill(bg, outline_wa.x, outline_wa.y)
    local border = clay.solid_rgba(border_color)
    local check_fill = clay.fill(check_color, content_wa.x, content_wa.y)
    local border_width = w:get_border_width() or 1
    if main_color and not main_fill then
        clay.ignore(w, "color", "is not a solid or a gradient and is transparent")
    elseif main_color and not main and not border and border_width > 0 then
        clay.ignore(w, "color", "is not solid and the outline is black")
    end
    if bg and not background then
        clay.ignore(w, "bg", "is not a solid or a gradient and is transparent")
    end
    if border_color and not border then
        clay.ignore(w, "border_color", "is not solid and is transparent")
    end
    if check_color and not check_fill then
        clay.ignore(w, "check_color", "is not a solid or a gradient and is transparent")
    end

    local background_shape = w:get_shape() or shape.rectangle
    local stroke = border or main or { 0, 0, 0, 1 }
    local outline = { w = "grow", h = "grow", fill = background,
        stroke = border_width > 0 and stroke or nil, stroke_width = border_width,
        shape = function(width, height)
            local size = math.min(width, height)
            local wa = outline_workarea(w, size, size)
            return clay.shape_ops(background_shape, wa.width, wa.height, wa.x, wa.y)
        end }
    local check
    if w._private.checked then
        check = { float = true, w = "grow", h = "grow",
            fill = check_fill or main_fill or stroke,
            shape = function(width, height)
                local size = math.min(width, height)
                local wa = content_workarea(w, size, size)
                return clay.shape_ops(background_shape, wa.width, wa.height, wa.x, wa.y)
            end }
    end
    return { w = side, h = side, wsrc = src, hsrc = src, specs = { outline, check } }
end

checkbox._clay = { describe = describe_checkbox }

--- If the checkbox is checked.
-- @property checked
-- @tparam[opt=false] boolean checked

for _, prop in ipairs {"border_width", "bg", "border_color", "check_color", "shape",
    "paddings", "checked", "color" } do
    checkbox["set_"..prop] = function(self, value)
        self._private[prop] = value
        self:emit_signal("property::"..prop, value)
        self:emit_signal("widget::redraw_needed")
    end
    checkbox["get_"..prop] = function(self)
        return self._private[prop] or beautiful["checkbox_"..prop]
    end
end

clay.retire(checkbox, {"check_border_color", "check_border_width", "check_shape"})

function checkbox:set_paddings(val)
    self._private.paddings = type(val) == "number" and {
        left   = val,
        right  = val,
        top    = val,
        bottom = val,
    } or val or {}
    self:emit_signal("property::paddings")
    self:emit_signal("widget::redraw_needed")
end

--- Create a new checkbox.
-- @constructorfct wibox.widget.checkbox
-- @tparam[opt=false] boolean checked
-- @tparam[opt] table args
-- @tparam gears.color args.color The color.

local function new(checked, args)
    checked, args = checked or false, args or {}

    local ret = base.make_widget(nil, nil, {
        enable_properties = true,
    })

    gtable.crush(ret, checkbox)

    ret._private.checked = checked
    ret._private.color = args.color and color(args.color) or nil


    return ret
end

return setmetatable({}, { __call = function(_, ...) return new(...) end})

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
