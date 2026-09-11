---------------------------------------------------------------------------
-- A circular progressbar wrapper.
--
-- If no child `widget` is set, then the radialprogressbar will take all the
-- available size. Use a `wibox.container.constraint` to prevent this.
--
--@DOC_wibox_container_defaults_radialprogressbar_EXAMPLE@
-- @author Emmanuel Lepage Vallee &lt;elv1313@gmail.com&gt;
-- @copyright 2013 Emmanuel Lepage Vallee
-- @containermod wibox.container.radialprogressbar
-- @supermodule wibox.widget.base
---------------------------------------------------------------------------

local setmetatable = setmetatable
local base      = require("wibox.widget.base")
local shape     = require("gears.shape"      )
local gtable    = require( "gears.table"     )
local beautiful = require("beautiful"        )
local clay      = require("wibox.clay"       )

local default_outline_width  = 2

local radialprogressbar = { mt = {} }

--- The progressbar border background color.
--
-- @beautiful beautiful.radialprogressbar_border_color
-- @param color

--- The progressbar foreground color.
--
-- @beautiful beautiful.radialprogressbar_color
-- @param color

--- The progressbar border width.
--
-- @beautiful beautiful.radialprogressbar_border_width
-- @param number

--- The padding between the outline and the progressbar.
-- @beautiful beautiful.radialprogressbar_paddings
-- @tparam[opt=0] table|number paddings A number or a table
-- @tparam[opt=0] number paddings.top
-- @tparam[opt=0] number paddings.bottom
-- @tparam[opt=0] number paddings.left
-- @tparam[opt=0] number paddings.right

local function outline_workarea(self, width, height)
    local border_width = self._private.border_width or
        beautiful.radialprogressbar_border_width or default_outline_width

    local x, y = 0, 0

    -- Make sure the border fit in the clip area
    local offset = border_width/2
    x, y = x + offset, y+offset
    width, height = width-2*offset, height-2*offset

    return {x=x, y=y, width=width, height=height}, offset
end






--- The widget to wrap in a radial proggressbar.
--
-- @property widget
-- @tparam[opt=nil] widget|nil widget
-- @interface container

radialprogressbar.set_widget = base.set_widget_common

function radialprogressbar:get_children()
    return {self._private.widget}
end

function radialprogressbar:set_children(children)
    self._private.widget = children and children[1]
    self:emit_signal("widget::layout_changed")
end

--- Reset this container.
--
-- @method reset
-- @noreturn
-- @interface container
function radialprogressbar:reset()
    self:set_widget(nil)
end

for _,v in ipairs {"left", "right", "top", "bottom"} do
    radialprogressbar["set_"..v.."_padding"] = function(self, val)
        self._private.paddings = self._private.paddings or {}
        self._private.paddings[v] = val
        self:emit_signal("widget::redraw_needed")
        self:emit_signal("widget::layout_changed")
    end
end

--- The padding between the outline and the progressbar.
--
--@DOC_wibox_container_radialprogressbar_padding_EXAMPLE@
-- @property paddings
-- @tparam[opt=0] table|number|nil paddings A number or a table
-- @tparam[opt=0] number paddings.top
-- @tparam[opt=0] number paddings.bottom
-- @tparam[opt=0] number paddings.left
-- @tparam[opt=0] number paddings.right
-- @propertytype number A single value for each sides.
-- @propertytype table A different value for each side.
-- @negativeallowed false
-- @propertyunit pixel
-- @propbeautiful
-- @propemits false false

--- The progressbar value.
--
--@DOC_wibox_container_radialprogressbar_value_EXAMPLE@
-- @property value
-- @tparam[opt=0] number value
-- @rangestart `min_value`
-- @rangestop `max_value`
-- @negativeallowed true
-- @propemits true false

function radialprogressbar:set_value(val)
    if not val then self._percent = 0; return end

    if val > self._private.max_value then
        self:set_max_value(val)
    elseif val < self._private.min_value then
        self:set_min_value(val)
    end

    local delta = self._private.max_value - self._private.min_value

    self._percent = val/delta
    self:emit_signal("widget::redraw_needed")
    self:emit_signal("property::value", val)
end

--- The border background color.
--
--@DOC_wibox_container_radialprogressbar_border_color_EXAMPLE@
-- @property border_color
-- @tparam color|nil border_color
-- @propbeautiful
-- @propemits true false

--- The border foreground color.
--
--@DOC_wibox_container_radialprogressbar_color_EXAMPLE@
-- @property color
-- @tparam color|nil color
-- @propbeautiful
-- @propemits true false

--- The border width.
--
--@DOC_wibox_container_radialprogressbar_border_width_EXAMPLE@
-- @property border_width
-- @tparam[opt=2] number|nil border_width
-- @negativeallowed false
-- @propertyunit pixel
-- @propbeautiful
-- @propemits true false

--- The minimum value.
--
-- @property min_value
-- @tparam[opt=0] number min_value
-- @negativeallowed true
-- @propemits true false

--- The maximum value.
--
-- @property max_value
-- @tparam[opt=1] number max_value
-- @negativeallowed true
-- @propemits true false

for _, prop in ipairs {"max_value", "min_value", "border_color", "color",
    "border_width", "paddings"} do
    radialprogressbar["set_"..prop] = function(self, value)
        self._private[prop] = value
        self:emit_signal("property::"..prop, value)
        self:emit_signal("widget::redraw_needed")
    end
    radialprogressbar["get_"..prop] = function(self)
        return self._private[prop] or beautiful["radialprogressbar_"..prop]
    end
end

function radialprogressbar:set_paddings(val)
    self._private.paddings = type(val) == "number" and {
        left   = val,
        right  = val,
        top    = val,
        bottom = val,
    } or val or {}
    self:emit_signal("property::paddings")
    self:emit_signal("widget::redraw_needed")
    self:emit_signal("widget::layout_changed")
end

--- Returns a new radialprogressbar layout.
--
-- A radialprogressbar layout  radialprogressbars a given widget. Use `.widget`
-- to set the widget.
--
-- @tparam[opt] widget widget The widget to display.
-- @constructorfct wibox.container.radialprogressbar
local function new(widget)
    local ret = base.make_widget(nil, nil, {
        enable_properties = true,
    })

    gtable.crush(ret, radialprogressbar)
    ret._private.max_value = 1
    ret._private.min_value = 0

    ret:set_widget(widget)

    return ret
end

function radialprogressbar.mt:__call(...)
    return new(...)
end

local function describe_radialprogressbar(w)

    local border = clay.solid_rgba(w:get_border_color() or "#0000ff")
    local progress = clay.solid_rgba(w:get_color() or "#ff00ff")
    if not border then
        clay.ignore(w, "border_color", "is not solid and is transparent")
    end
    if not progress then
        clay.ignore(w, "color", "is not solid and is transparent")
    end

    local bw = w._private.border_width or
        beautiful.radialprogressbar_border_width or default_outline_width
    local percent = w._percent or 0
    local padding = w._private.paddings or {}
    local pad = {}
    for i, side in ipairs { "left", "right", "top", "bottom" } do
        pad[i] = clay.pixels(w, "paddings." .. side, bw / 2 + (padding[side] or 0))
    end

    -- render.c rounded_rect_path clamps PILL to half the shorter side,
    -- cutting the child to the same pill as before_draw_children.
    local PILL = 1e6
    local node = { pad = pad, specs = {
        { w = "grow", h = "grow", radius = PILL,
            children = clay.whole_box(w._private.widget) },
    } }
    if border then
        node.specs[#node.specs + 1] = { float = true, w = "grow", h = "grow", stroke = border, stroke_width = bw,
            shape = function(width, height)
                local wa = outline_workarea(w, width, height)
                return clay.shape_ops(shape.rounded_bar, wa.width, wa.height, wa.x, wa.y)
            end }
    end
    if progress then
        node.specs[#node.specs + 1] = { float = true, w = "grow", h = "grow", stroke = progress, stroke_width = bw,
            shape = function(width, height)
                local wa = outline_workarea(w, width, height)
                return clay.shape_ops(shape.radial_progress, wa.width, wa.height, wa.x, wa.y, percent)
            end }
    end
    if not w._private.widget then
        node.w, node.h = "grow", "grow"
    end
    return node
end

radialprogressbar._clay = { describe = describe_radialprogressbar }

return setmetatable(radialprogressbar, radialprogressbar.mt)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
