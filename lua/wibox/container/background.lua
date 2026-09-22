---------------------------------------------------------------------------
-- A container capable of changing the background color, foreground color and
-- widget shape.
--
--@DOC_wibox_container_defaults_background_EXAMPLE@
-- @author Uli Schlachter
-- @copyright 2010 Uli Schlachter
-- @containermod wibox.container.background
-- @supermodule wibox.widget.base
---------------------------------------------------------------------------

local clay = require("wibox.clay")
local base = require("wibox.widget.base")
local color = require("gears.color")
local surface = require("gears.surface")
local beautiful = require("beautiful")
local gtable = require("gears.table")
local gshape = require("gears.shape")
local setmetatable = setmetatable
local type = type

local background = { mt = {} }








--- The widget displayed in the background widget.
-- @property widget
-- @tparam[opt=nil] widget|nil widget The widget to be disaplayed inside of
--  the background area.
-- @interface container

background.set_widget = base.set_widget_common

function background:get_widget()
    return self._private.widget
end

function background:get_children()
    return {self._private.widget}
end

function background:set_children(children)
    self:set_widget(children[1])
end

--- Stretch the background gradient horizontally.
--
-- This only works for linear or radial gradients. It does nothing
-- for solid colors, `bgimage` or raster patterns.
--
--@DOC_wibox_container_background_stretch_horizontally_EXAMPLE@
--
-- @property stretch_horizontally
-- @tparam[opt=false] boolean stretch_horizontally
-- @propemits true false
-- @see stretch_vertically
-- @see bg
-- @see gears.color

--- Stretch the background gradient vertically.
--
-- This only works for linear or radial gradients. It does nothing
-- for solid colors, `bgimage` or raster patterns.
--
--@DOC_wibox_container_background_stretch_vertically_EXAMPLE@
--
-- @property stretch_vertically
-- @tparam[opt=false] boolean stretch_vertically
-- @propemits true false
-- @see stretch_horizontally
-- @see bg
-- @see gears.color

for _, orientation in ipairs {"horizontally", "vertically"} do
    background["set_stretch_"..orientation] = function(self, value)
        self._private["stretch_"..orientation] = value
        self:emit_signal("widget::redraw_needed")
        self:emit_signal("property::stretch_"..orientation, value)
    end
end

--- The background color/pattern/gradient to use.
--
--@DOC_wibox_container_background_bg_EXAMPLE@
--
-- @property bg
-- @tparam color bg
-- @propertydefault When unspecified, it will inherit the value from an higher
--  level `wibox.container.background` or directly from the `wibox.bg` property.
-- @see gears.color
-- @propemits true false

function background:set_bg(bg)
    if bg then
        self._private.background = color(bg)
    else
        self._private.background = nil
    end
    self:emit_signal("widget::redraw_needed")
    self:emit_signal("property::bg", bg)
end

function background:get_bg()
    return self._private.background
end

--- The foreground (text) color/pattern/gradient to use.
--
--@DOC_wibox_container_background_fg_EXAMPLE@
--
-- @property fg
-- @tparam color fg A color string, pattern or gradient
-- @propertydefault When unspecified, it will inherit the value from an higher
--  level `wibox.container.background` or directly from the `wibox.fg` property.
-- @propemits true false
-- @see gears.color

function background:set_fg(fg)
    if fg then
        self._private.foreground = color(fg)
    else
        self._private.foreground = nil
    end
    self:emit_signal("widget::redraw_needed")
    self:emit_signal("property::fg", fg)
end

function background:get_fg()
    return self._private.foreground
end

--- The background shape.
--
-- Use `set_shape` to set additional shape paramaters.
--
--@DOC_wibox_container_background_shape_EXAMPLE@
--
-- @property shape
-- @tparam[opt=gears.shape.rectangle] shape shape
-- @see gears.shape
-- @see set_shape

--- Set the background shape.
--
-- Any other arguments will be passed to the shape function.
--
-- @method set_shape
-- @tparam gears.shape|function shape A function taking a context, width and height as arguments
-- @noreturn
-- @propemits true false
-- @see gears.shape
-- @see shape
function background:set_shape(shape, ...)
    local args = {...}

    if shape == self._private.shape and #args == 0 then return end

    self._private.shape = shape
    self._private.shape_args = {...}
    self:emit_signal("widget::redraw_needed")
    self:emit_signal("property::shape", shape)
end

function background:get_shape()
    return self._private.shape
end

--- Add a border of a specific width.
--
-- If the shape is set, the border will also be shaped.
--
--@DOC_wibox_container_background_border_width_EXAMPLE@
--
-- @property border_width
-- @tparam[opt=0] number border_width
-- @propertyunit pixel
-- @negativeallowed false
-- @propemits true false
-- @introducedin 4.4
-- @see border_color

function background:set_border_width(width)
    if self._private.shape_border_width == width then return end

    self._private.shape_border_width = width
    self:emit_signal("widget::redraw_needed")
    self:emit_signal("property::border_width", width)
end

function background:get_border_width()
    return self._private.shape_border_width
end

--- Set the color for the border.
--
--@DOC_wibox_container_background_border_color_EXAMPLE@
--
-- See `wibox.container.background.shape` for an usage example.
-- @property border_color
-- @tparam color border_color
-- @propertydefault `wibox.container.background.fg` if set, otherwise `beautiful.fg_normal`.
-- @propemits true false
-- @usebeautiful beautiful.fg_normal Fallback when 'fg' and `border_color` aren't set.
-- @introducedin 4.4
-- @see gears.color
-- @see border_width

function background:set_border_color(fg)
    if self._private.shape_border_color == fg then return end

    self._private.shape_border_color = fg
    self:emit_signal("widget::redraw_needed")
    self:emit_signal("property::border_color", fg)
end

function background:get_border_color()
    return self._private.shape_border_color
end

function background:set_shape_clip(value)
    if value then return end
    require("gears.debug").print_warning("shape_clip property of background container was removed."
        .. " Use wibox.layout.stack instead if you want shape_clip=false.")
end

function background:get_shape_clip()
    require("gears.debug").print_warning("shape_clip property of background container was removed."
        .. " Use wibox.layout.stack instead if you want shape_clip=false.")
    return true
end

--- How the border width affects the contained widget.
--
--@DOC_wibox_container_background_border_strategy_EXAMPLE@
--
-- @property border_strategy
-- @tparam[opt="none"] string border_strategy
-- @propertyvalue "none" Just apply the border, do not affect the content size (default).
-- @propertyvalue "inner" Squeeze the size of the content by the border width.
-- @propemits true false

function background:set_border_strategy(value)
    self._private.border_strategy = value
    self:emit_signal("widget::layout_changed")
    self:emit_signal("property::border_strategy", value)
end

--- The background image to use.
--
-- This property is deprecated. The `wibox.container.border` provides a much
-- more fine-grained support for background images. It is now out of the
-- `wibox.container.background` scope. `wibox.layout.stack` can also be used
-- to overlay a widget on top of a `wibox.widget.imagebox`. This solution
-- exposes all availible imagebox properties. Finally, if you wish to use the
-- `function` callback support, implement the `before_draw_children` method
-- on any widget. This gives you the same level of control without all the
-- `bgimage` corner cases.
--
-- If `image` is a function, it will be called with `(context, cr, width, height)`
-- as arguments. Any other arguments passed to this method will be appended.
--
-- @deprecatedproperty bgimage
-- @tparam string|surface|function bgimage A background image or a function.
-- @see gears.surface
-- @see wibox.container.border
-- @see wibox.widget.imagebox
-- @see wibox.layout.stack

function background:set_bgimage(image, ...)
    -- Unset stays unset: gears.surface.load(nil) answers an empty default
    -- surface, which paints nothing and would still make the container a
    -- painter to the Clay compile step (wibox.clay). The list widgets set
    -- nil on every item.
    if image == nil then
        self._private.bgimage = nil
    else
        self._private.bgimage = type(image) == "function" and image or surface.load(image)
    end
    self._private.bgimage_args = {...}
    self:emit_signal("widget::redraw_needed")
    self:emit_signal("property::bgimage", image)
end

function background:get_bgimage()
    return self._private.bgimage
end

--- Returns a new background container.
--
-- A background container applies a background and foreground color
-- to another widget.
--
-- @tparam[opt] widget widget The widget to display.
-- @tparam[opt] color bg The background to use for that widget.
-- @tparam[opt] gears.shape|function shape A `gears.shape` compatible shape function
-- @constructorfct wibox.container.background
local function new(widget, bg, shape)
    local ret = base.make_widget(nil, nil, {
        enable_properties = true,
    })

    gtable.crush(ret, background, true)

    ret._private.shape = shape
    ret._private.scale_cache = {}
    ret._private.scale_cache_size = 0

    ret:set_widget(widget)
    ret:set_bg(bg)

    return ret
end

function background.mt:__call(...)
    return new(...)
end

--- wibox.container.background -> a rectangle color, a corner radius and a
-- border.
--
-- Clay draws a border inside the element box without moving its children,
-- which is what `border_strategy = "none"` does; "inner" adds the padding
-- that shrinks them.
local function describe_background(w)
    local p = w._private

    local bw = clay.pixels(w, "shape_border_width", p.shape_border_width)
    local radius = clay.shape_radius(p.shape, p.shape_args)

    if not radius then
        clay.ignore(w, "shape", "is not a rounded rectangle and draws as its box")
        radius = 0
    end

    local node = { radius = radius, specs = clay.whole_box(p.widget) }

    if type(p.bgimage) == "function" then
        clay.ignore(w, "bgimage", "is a function and is not drawn")
    elseif p.bgimage then
        node.specs = { { image = p.bgimage._native, class = "image", natural = true,
            w = "grow", h = "grow", children = clay.whole_box(p.widget) } }
    end

    if p.background then
        node.bg = clay.solid_rgba(p.background)
        if not node.bg then
            local fill = clay.fill(p.background)
            if not fill then
                clay.ignore(w, "bg", "is not a solid or a gradient and is transparent")
            else
                node.fill = fill
                node.shape = function(width, height)
                    return clay.shape_ops(gshape.rounded_rect, width, height, 0, 0, radius)
                end
            end
        end
    end

    if bw > 0 then
        -- No color at all is black, which is what gears.color makes of nil.
        node.border = clay.solid_rgba(p.shape_border_color or p.foreground
            or beautiful.fg_normal or "#000000")
        if not node.border then
            clay.ignore(w, "shape_border_color", "is not solid and the border is transparent")
        else
            node.bw = { bw, bw, bw, bw }
            if p.border_strategy == "inner" then
                node.pad = { bw, bw, bw, bw }
            end
        end
    end

    -- A background's fg is the source its children draw with, so it rides
    -- alongside the node rather than in it: a leaf takes the innermost one.
    return node, p.foreground
end

background._clay = { describe = describe_background }

return setmetatable(background, background.mt)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
