---------------------------------------------------------------------------
-- An interactive mouse based slider widget.
--
--@DOC_wibox_widget_defaults_slider_EXAMPLE@
--
-- @author Grigory Mishchenko &lt;grishkokot@gmail.com&gt;
-- @author Emmanuel Lepage Vallee &lt;elv1313@gmail.com&gt;
-- @copyright 2015 Grigory Mishchenko, 2016 Emmanuel Lepage Vallee
-- @widgetmod wibox.widget.slider
-- @supermodule wibox.widget.base
---------------------------------------------------------------------------

local setmetatable = setmetatable
local type = type
local gmatrix = require("gears.matrix")
local gtable = require("gears.table")
local beautiful = require("beautiful")
local base = require("wibox.widget.base")
local clay = require("wibox.clay")
local shape = require("gears.shape")
local capi = {
    mouse        = mouse,
    mousegrabber = mousegrabber,
    root         = root,
}

local slider = {mt={}}

--- The slider handle shape.
--
--@DOC_wibox_widget_slider_handle_shape_EXAMPLE@
--
-- @property handle_shape
-- @tparam shape|nil handle_shape
-- @propemits true false
-- @propbeautiful
-- @see gears.shape

--- The slider handle color.
--
--@DOC_wibox_widget_slider_handle_color_EXAMPLE@
--
-- @property handle_color
-- @propbeautiful
-- @tparam color|nil handle_color
-- @propemits true false

--- The slider handle margins.
--
--@DOC_wibox_widget_slider_handle_margins_EXAMPLE@
--
-- @property handle_margins
-- @tparam[opt={}] table|number|nil handle_margins
-- @tparam[opt=0] number handle_margins.left
-- @tparam[opt=0] number handle_margins.right
-- @tparam[opt=0] number handle_margins.top
-- @tparam[opt=0] number handle_margins.bottom
-- @propertyunit pixel
-- @propertytype number A single value used for all sides.
-- @propertytype table A different value for each side. The side names are:
-- @negativeallowed true
-- @propemits true false
-- @propbeautiful

--- The slider handle width.
--
--@DOC_wibox_widget_slider_handle_width_EXAMPLE@
--
-- @property handle_width
-- @tparam number|nil handle_width
-- @negativeallowed false
-- @propertyunit pixel
-- @propemits true false
-- @propbeautiful

--- The handle border_color.
--
--@DOC_wibox_widget_slider_handle_border_EXAMPLE@
--
-- @property handle_border_color
-- @tparam color|nil handle_border_color
-- @propemits true false
-- @propbeautiful

--- The handle border width.
-- @property handle_border_width
-- @tparam[opt=0] number|nil handle_border_width
-- @propertyunit pixel
-- @negativeallowed false
-- @propemits true false
-- @propbeautiful

--- The cursor icon while grabbing the handle.
-- The available cursor names are:
--
--@DOC_cursor_COMMON@
--
-- @property handle_cursor
-- @tparam[opt="fleur"] string|nil handle_cursor
-- @propbeautiful
-- @see mousegrabber

--- The bar (background) shape.
--
--@DOC_wibox_widget_slider_bar_shape_EXAMPLE@
--
-- @property bar_shape
-- @tparam shape|nil bar_shape
-- @propemits true false
-- @propbeautiful
-- @see gears.shape

--- The bar (background) height.
--
--@DOC_wibox_widget_slider_bar_height_EXAMPLE@
--
-- @property bar_height
-- @tparam number|nil bar_height
-- @propertyunit pixel
-- @negativeallowed false
-- @propbeautiful
-- @propemits true false

--- The bar (background) color.
--
--@DOC_wibox_widget_slider_bar_color_EXAMPLE@
--
-- @property bar_color
-- @tparam color|nil bar_color
-- @propbeautiful
-- @propemits true false

--- The bar (active) color.
--
--@DOC_wibox_widget_slider_bar_active_color_EXAMPLE@
--
-- Only works when both `bar_active_color` and `bar_color` are passed as hex color string
-- @property bar_active_color
-- @tparam color|nil bar_active_color
-- @propbeautiful
-- @propemits true false

--- The bar (background) margins.
--
--@DOC_wibox_widget_slider_bar_margins_EXAMPLE@
--
-- @property bar_margins
-- @tparam[opt={}] table|number|nil bar_margins
-- @tparam[opt=0] number bar_margins.left
-- @tparam[opt=0] number bar_margins.right
-- @tparam[opt=0] number bar_margins.top
-- @tparam[opt=0] number bar_margins.bottom
-- @propertyunit pixel
-- @propertytype number A single value used for all sides.
-- @propertytype table A different value for each side. The side names are:
-- @negativeallowed true
-- @propbeautiful
-- @propemits true false

--- The bar (background) border width.
-- @property bar_border_width
-- @tparam[opt=0] number|nil bar_border_width
-- @propertyunit pixel
-- @negativeallowed false
-- @propemits true false
-- @propbeautiful

--- The bar (background) border_color.
--
--@DOC_wibox_widget_slider_bar_border_EXAMPLE@
--
-- @property bar_border_color
-- @tparam color|nil bar_border_color
-- @propbeautiful
-- @propemits true false

--- The slider value.
--
--@DOC_wibox_widget_slider_value_EXAMPLE@
--
-- @property value
-- @tparam[opt=0] number value
-- @negativeallowed true
-- @propemits true false

--- The slider minimum value.
--
-- @property minimum
-- @tparam[opt=0] number minimum
-- @negativeallowed true
-- @propemits true false

--- The slider maximum value.
--
-- @property maximum
-- @tparam[opt=100] number maximum
-- @negativeallowed true
-- @propemits true false

--- The bar (background) border width.
--
-- @beautiful beautiful.slider_bar_border_width
-- @param number

--- The bar (background) border color.
--
-- @beautiful beautiful.slider_bar_border_color
-- @param color

--- The handle border_color.
--
-- @beautiful beautiful.slider_handle_border_color
-- @param color

--- The handle border width.
--
-- @beautiful beautiful.slider_handle_border_width
-- @param number

--- The handle width.
--
-- @beautiful beautiful.slider_handle_width
-- @param number

--- The handle color.
--
-- @beautiful beautiful.slider_handle_color
-- @param color

--- The handle shape.
--
-- @beautiful beautiful.slider_handle_shape
-- @tparam[opt=gears.shape.rectangle] gears.shape shape
-- @see gears.shape

--- The cursor icon while grabbing the handle.
-- The available cursor names are:
--
--@DOC_cursor_COMMON@
--
-- @beautiful beautiful.slider_handle_cursor
-- @tparam[opt="fleur"] string cursor
-- @see mousegrabber

--- The bar (background) shape.
--
-- @beautiful beautiful.slider_bar_shape
-- @tparam[opt=gears.shape.rectangle] gears.shape shape
-- @see gears.shape

--- The bar (background) height.
--
-- @beautiful beautiful.slider_bar_height
-- @param number

--- The bar (background) margins.
--
-- @beautiful beautiful.slider_bar_margins
-- @tparam[opt={}] table margins
-- @tparam[opt=0] number margins.left
-- @tparam[opt=0] number margins.right
-- @tparam[opt=0] number margins.top
-- @tparam[opt=0] number margins.bottom

--- The slider handle margins.
--
-- @beautiful beautiful.slider_handle_margins
-- @tparam[opt={}] table margins
-- @tparam[opt=0] number margins.left
-- @tparam[opt=0] number margins.right
-- @tparam[opt=0] number margins.top
-- @tparam[opt=0] number margins.bottom

--- The bar (background) color.
--
-- @beautiful beautiful.slider_bar_color
-- @param color

--- The bar (active) color.
--
-- Only works when both `beautiful.slider_bar_color` and `beautiful.slider_bar_active_color` are hex color strings
-- @beautiful beautiful.slider_bar_active_color
-- @param color


local properties = {
    -- Handle
    handle_shape         = shape.rectangle,
    handle_color         = false,
    handle_margins       = {},
    handle_width         = false,
    handle_border_width  = 0,
    handle_border_color  = false,
    handle_cursor        = "fleur",

    -- Bar
    bar_shape            = shape.rectangle,
    bar_height           = false,
    bar_color            = false,
    bar_active_color     = false,
    bar_margins          = {},
    bar_border_width     = 0,
    bar_border_color     = false,

    -- Content
    value                = 0,
    minimum              = 0,
    maximum              = 100,
}

-- Create the accessors
for prop in pairs(properties) do
    slider["set_"..prop] = function(self, value)
        local changed = self._private[prop] ~= value
        self._private[prop] = value

        if changed then
            self:emit_signal("property::"..prop, value)
            self:emit_signal("widget::redraw_needed")
        end
    end

    slider["get_"..prop] = function(self)
        -- Ignoring the false's is on purpose
        return self._private[prop] == nil
            and properties[prop]
            or self._private[prop]
    end
end

-- Add some validation to set_value
function slider:set_value(value)
    value = math.min(value, self:get_maximum())
    value = math.max(value, self:get_minimum())
    local changed = self._private.value ~= value

    self._private.value = value

    if changed then
        self:emit_signal( "property::value", value)
        self:emit_signal( "widget::redraw_needed" )
    end
end

local function get_extremums(self)
    local min = self._private.minimum or properties.minimum
    local max = self._private.maximum or properties.maximum
    local interval = max - min

    return min, max, interval
end



local function describe_slider(w)
    local p = w._private
    local bbw = p.bar_border_width or beautiful.slider_bar_border_width or 0
    if bbw > 0 then
        clay.ignore(w, "bar_border_width", "is not drawn")
    end

    local bar_color = p.bar_color or beautiful.slider_bar_color
    local active = p.bar_active_color or beautiful.slider_bar_active_color
    local handle_color = p.handle_color or beautiful.slider_handle_color
    local handle_border_color = p.handle_border_color or beautiful.slider_handle_border_color
    local background = clay.solid_rgba(bar_color)
    local active_fill = clay.solid_rgba(active)
    local handle_fill = clay.solid_rgba(handle_color)
    local handle_stroke = clay.solid_rgba(handle_border_color)
    if bar_color and not background then
        clay.ignore(w, "bar_color", "is not solid and is transparent")
    end
    if active and not active_fill then
        clay.ignore(w, "bar_active_color", "is not solid and is transparent")
    end
    if handle_color and not handle_fill then
        clay.ignore(w, "handle_color", "is not solid and is transparent")
    end
    if handle_border_color and not handle_stroke then
        clay.ignore(w, "handle_border_color", "is not solid and is transparent")
    end

    local margins = p.bar_margins or beautiful.slider_bar_margins
    local bar_h = p.bar_height or (not margins and beautiful.slider_bar_height)
    local bar_margins, handle_margins = {}, {}
    for i, prop in ipairs { "bar_margins", "handle_margins" } do
        local value = p[prop] or beautiful["slider_" .. prop]
        local sides = i == 1 and bar_margins or handle_margins
        for j, side in ipairs { "left", "right", "top", "bottom" } do
            local v = type(value) == "number" and value or (value and value[side] or 0)
            sides[j] = clay.pixels(w, prop .. "." .. side, v)
        end
    end
    if bar_h then
        bar_h = clay.pixels(w, "bar_height", bar_h)
    end

    local hw = p.handle_width or beautiful.slider_handle_width
    local hbw = p.handle_border_width or beautiful.slider_handle_border_width or 0
    local draws_active = type(bar_color) == "string" and type(active) == "string"
        and active_fill ~= nil
    if draws_active and not hw and bar_h then
        clay.ignore(w, "handle_width", "is unset with a bar_height and is half the bar's height")
    end
    if draws_active and not handle_color then
        clay.ignore(w, "handle_color", "is unset and the handle takes the bar colour")
    end
    local bar_shape = p.bar_shape or beautiful.slider_bar_shape or properties.bar_shape
    local radius = clay.shape_radius(bar_shape)
    if draws_active and radius == nil then
        clay.ignore(w, "bar_shape", "does not cut the active bar")
    end

    local value = p.value or p.min or 0
    local maximum = p.maximum or properties.maximum
    local minimum = p.minimum or properties.minimum
    local range = maximum - minimum
    local rate = range > 0 and (value - minimum) / range or 0
    local handle_shape = p.handle_shape or beautiful.slider_handle_shape or properties.handle_shape
    handle_fill = handle_fill or background or { 0, 0, 0, 1 }
    if not handle_border_color then
        handle_stroke = handle_fill
    end

    local bar = { w = "grow", h = bar_h or "grow" }
    if radius then
        bar.bg, bar.radius = background, radius
    else
        bar.fill = background
        bar.shape = function(width, height)
            return clay.shape_ops(bar_shape, width, height)
        end
    end
    if draws_active then
        bar.children = { { w = "grow", h = "grow", fill = active_fill,
            shape = function(width, height)
                local slider_height = bar_h and height or height + bar_margins[3] + bar_margins[4]
                local handle_width = hw or math.floor(slider_height / 2)
                local baw = math.floor(rate * width - (handle_width - hbw / 2) * (rate - 0.5))
                if baw <= 0 then
                    return {}
                end
                return clay.shape_ops(shape.rectangle, 0.99 * baw, height)
            end } }
    end
    -- Floating grow elements take their parent's box (third_party/clay.h:2224-2237)
    -- and paint in declaration order at equal zIndex (:2603-2615).
    return { w = "grow", h = "grow", specs = {
        { float = true, w = "grow", h = "grow", pad = bar_margins,
            align = { y = margins and "top" or "center" }, children = { bar } },
        { float = true, w = "grow", h = "grow", fill = handle_fill,
            stroke = hbw > 0 and handle_stroke or nil, stroke_width = hbw,
            shape = function(width, height)
                local handle_width = hw or math.floor(height / 2)
                local handle_height = height
                local xo, yo = handle_margins[1], handle_margins[3]
                handle_width = handle_width - handle_margins[1] - handle_margins[2]
                handle_height = handle_height - handle_margins[3] - handle_margins[4]
                local rel = math.floor(rate * (width - handle_width))
                return clay.shape_ops(handle_shape, handle_width, handle_height, xo + rel, yo)
            end },
    } }
end

slider._clay = { describe = describe_slider }

-- Move the handle to the correct location
local function move_handle(self, width, x, _)
    local min, _, interval = get_extremums(self)
    self:set_value(min+math.floor((x*interval)/width))
end

local function mouse_press(self, x, y, button_id, _, geo)
    if button_id ~= 1 then return end

    -- Sigh. geo.width/geo.height is in device space. We need it in our own
    -- coordinate system
    local width = geo.widget_width

    move_handle(self, width, x, y)

    -- Calculate a matrix transforming from screen coordinates into widget coordinates
    local wgeo = geo.drawable.drawable:geometry()
    local matrix = gmatrix.create_translate(-wgeo.x - geo.x, -wgeo.y - geo.y)

    local handle_cursor = self._private.handle_cursor
        or beautiful.slider_handle_cursor
        or properties.handle_cursor

    capi.mousegrabber.run(function(mouse)
        if not mouse.buttons[1] then
            return false
        end

        -- Calculate the point relative to the widget
        move_handle(self, width, matrix:transform_point(mouse.x, mouse.y))

        return true
    end,handle_cursor)
end

--- Create a slider widget.
--
-- @constructorfct wibox.widget.slider
-- @tparam[opt={}] table args
-- @tparam[opt] gears.shape args.handle_shape The slider handle shape.
-- @tparam[opt] color args.handle_color The slider handle color.
-- @tparam[opt] table args.handle_margins The slider handle margins.
-- @tparam[opt] number args.handle_width The slider handle width.
-- @tparam[opt] color args.handle_border_color The handle border_color.
-- @tparam[opt] number args.handle_border_width The handle border width.
-- @tparam[opt] string args.handle_cursor
--   The cursor icon while grabbing the handle.
--   The available cursor names are listed under handle_cursor, in the "Object properties" section.
-- @tparam[opt] gears.shape args.bar_shape The bar (background) shape.
-- @tparam[opt] number args.bar_height The bar (background) height.
-- @tparam[opt] color args.bar_color The bar (background) color.
-- @tparam[opt] color args.bar_active_color The bar (active) color.
-- @tparam[opt] table args.bar_margins The bar (background) margins.
-- @tparam[opt] number args.bar_border_width The bar (background) border width.
-- @tparam[opt] color args.bar_border_color The bar (background) border_color.
-- @tparam[opt] number args.value The slider value.
-- @tparam[opt] number args.minimum The slider minimum value.
-- @tparam[opt] number args.maximum The slider maximum value.
local function new(args)
    local ret = base.make_widget(nil, nil, {
        enable_properties = true,
    })

    gtable.crush(ret._private, args or {})

    gtable.crush(ret, slider, true)

    ret:connect_signal("button::press", mouse_press)

    return ret
end

function slider.mt:__call(...)
    return new(...)
end

return setmetatable(slider, slider.mt)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
