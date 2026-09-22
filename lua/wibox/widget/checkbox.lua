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

--- The checked part border color.
--
-- @beautiful beautiful.checkbox_check_border_color
-- @param color

--- The checked part border width.
--
-- @beautiful beautiful.checkbox_check_border_width
-- @param number

--- The checked part filling color.
--
-- @beautiful beautiful.checkbox_check_color
-- @param number

--- The outer (unchecked area) shape.
--
-- @beautiful beautiful.checkbox_shape
-- @tparam gears.shape|function shape
-- @see gears.shape

--- The checked part shape.
--
-- If none is set, then the `shape` property will be used.
-- @beautiful beautiful.checkbox_check_shape
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

--- The checked part border color.
--
-- @property check_border_color
-- @tparam color|nil check_border_color
-- @propbeautiful
-- @propemits true false

--- The checked part border width.
--
-- @property check_border_width
-- @tparam number|nil check_border_width
-- @propbeautiful
-- @negativeallowed false
-- @propertyunit pixel
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

--- The checked part shape.
--
-- If none is set, then the `shape` property will be used.
--@DOC_wibox_widget_checkbox_check_shape_EXAMPLE@
-- @property check_shape
-- @tparam shape|nil check_shape
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
    local offset = self:get_check_border_width() or 0
    local wa = outline_workarea(self, width, height)

    wa.x      = offset + wa.x + (padding.left or 1)
    wa.y      = offset + wa.y + (padding.top  or 1)
    wa.width  = wa.width  - (padding.left or 1) - (padding.right  or 1) - 2*offset
    wa.height = wa.height - (padding.top  or 1) - (padding.bottom or 1) - 2*offset

    return wa
end



local function describe_checkbox(w)

    local main_color = w:get_color()
    local bg = w:get_bg()
    local border_color = w:get_border_color()
    local check_color = w:get_check_color()
    local check_border_color = w:get_check_border_color()
    local main = clay.solid_rgba(main_color)
    local background = clay.solid_rgba(bg)
    local border = clay.solid_rgba(border_color)
    local check_fill = clay.solid_rgba(check_color)
    local check_border = clay.solid_rgba(check_border_color)
    if main_color and not main then
        clay.ignore(w, "color", "is not solid and is transparent")
    end
    if bg and not background then
        clay.ignore(w, "bg", "is not solid and is transparent")
    end
    if border_color and not border then
        clay.ignore(w, "border_color", "is not solid and is transparent")
    end
    if check_color and not check_fill then
        clay.ignore(w, "check_color", "is not solid and is transparent")
    end
    if check_border_color and not check_border then
        clay.ignore(w, "check_border_color", "is not solid and is transparent")
    end

    local background_shape = w:get_shape() or shape.rectangle
    local border_width = w:get_border_width() or 1
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
        local check_shape = w:get_check_shape() or background_shape
        local check_border_width = w:get_check_border_width() or 0
        check = { float = true, w = "grow", h = "grow",
            fill = check_fill or main or stroke,
            stroke = check_border_width > 0 and (check_border or { 0, 0, 0, 1 }) or nil,
            stroke_width = check_border_width,
            shape = function(width, height)
                local size = math.min(width, height)
                local wa = content_workarea(w, size, size)
                return clay.shape_ops(check_shape, wa.width, wa.height, wa.x, wa.y)
            end }
    end
    local node = { square = true, specs = { outline, check } }
    return node
end

checkbox._clay = { describe = describe_checkbox }

--- If the checkbox is checked.
-- @property checked
-- @tparam[opt=false] boolean checked

for _, prop in ipairs {"border_width", "bg", "border_color", "check_border_color",
    "check_border_width", "check_color", "shape", "check_shape", "paddings",
    "checked", "color" } do
    checkbox["set_"..prop] = function(self, value)
        self._private[prop] = value
        self:emit_signal("property::"..prop, value)
        self:emit_signal("widget::redraw_needed")
    end
    checkbox["get_"..prop] = function(self)
        return self._private[prop] or beautiful["checkbox_"..prop]
    end
end

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
