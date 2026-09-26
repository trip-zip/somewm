---------------------------------------------------------------------------
--- A progressbar widget.
--
-- ![Components](../images/progressbar.svg)
--
-- Common usage examples
-- =====================
--
-- To add text on top of the progressbar, a `wibox.layout.stack` can be used:
--
--@DOC_wibox_widget_progressbar_text_EXAMPLE@
--
-- To display the progressbar vertically, use a `wibox.container.rotate` widget:
--
--@DOC_wibox_widget_progressbar_vertical_EXAMPLE@
--
-- By default, this widget will take all the available size. To prevent this,
-- a `wibox.container.constraint` widget or the `forced_width`/`forced_height`
-- properties have to be used.
--
-- To have a gradient between 2 colors when the bar reaches a threshold, use
-- the `gears.color` gradients:
--
--@DOC_wibox_widget_progressbar_grad1_EXAMPLE@
--
-- The same goes for multiple solid colors:
--
--@DOC_wibox_widget_progressbar_grad2_EXAMPLE@
--
--@DOC_wibox_widget_defaults_progressbar_EXAMPLE@
--
-- @author Julien Danjou &lt;julien@danjou.info&gt;
-- @copyright 2009 Julien Danjou
-- @widgetmod wibox.widget.progressbar
-- @supermodule wibox.widget.base
---------------------------------------------------------------------------

local setmetatable = setmetatable
local ipairs = ipairs
local math = math
local base = require("wibox.widget.base")
local beautiful = require("beautiful")
local shape = require("gears.shape")
local gtable = require("gears.table")
local clay = require("wibox.clay")

local progressbar = { mt = {} }

--- The progressbar border color.
--
-- If the value is nil, no border will be drawn.
--
-- @DOC_wibox_widget_progressbar_border_color_EXAMPLE@
--
-- @property border_color
-- @tparam color|nil border_color The border color to set.
-- @propemits true false
-- @propbeautiful
-- @see gears.color

--- The progressbar border width.
--
-- @DOC_wibox_widget_progressbar_border_width_EXAMPLE@
--
-- @property border_width
-- @tparam number|nil border_width
-- @propertytype nil Defaults to `beautiful.progressbar_border_width`.
-- @propertytype number The number of pixels
-- @propertyunit pixel
-- @negativeallowed false
-- @propbeautiful
-- @propemits true false
-- @propbeautiful

--- The progressbar inner border color.
--
-- If the value is nil, no border will be drawn.
--
-- @DOC_wibox_widget_progressbar_bar_border_color_EXAMPLE@
--
-- @property bar_border_color
-- @tparam color|nil bar_border_color The border color to set.
-- @propemits true false
-- @propbeautiful
-- @see gears.color

--- The progressbar inner border width.
--
-- @DOC_wibox_widget_progressbar_bar_border_width_EXAMPLE@
--
-- @property bar_border_width
-- @tparam number|nil bar_border_width
-- @propertyunit pixel
-- @negativeallowed false
-- @propbeautiful
-- @usebeautiful beautiful.progressbar_border_width Fallback when
--  `beautiful.progressbar_bar_border_width` isn't set.
-- @propemits true false

--- The progressbar foreground color.
--
-- @DOC_wibox_widget_progressbar_color_EXAMPLE@
--
-- @property color
-- @tparam color|nil color The progressbar color.
-- @propertytype nil Fallback to the current value of `beautiful.progressbar_fg`.
-- @propemits true false
-- @usebeautiful beautiful.progressbar_fg
-- @see gears.color

--- The progressbar background color.
--
-- @DOC_wibox_widget_progressbar_background_color_EXAMPLE@
--
-- @property background_color
-- @tparam color|nil background_color The progressbar background color.
-- @propertytype nil Fallback to the current value of `beautiful.progressbar_bg`.
-- @propemits true false
-- @usebeautiful beautiful.progressbar_bg
-- @see gears.color

--- The progressbar inner shape.
--
--@DOC_wibox_widget_progressbar_bar_shape_EXAMPLE@
--
-- @property bar_shape
-- @tparam shape|nil bar_shape
-- @propemits true false
-- @propbeautiful
-- @see gears.shape

--- The progressbar shape.
--
--@DOC_wibox_widget_progressbar_shape_EXAMPLE@
--
-- @property shape
-- @tparam shape|nil shape
-- @propemits true false
-- @propbeautiful
-- @see gears.shape

--- Force the inner part (the bar) to fit in the background shape.
--
--@DOC_wibox_widget_progressbar_clip_EXAMPLE@
--
-- @property clip
-- @tparam[opt=true] boolean clip
-- @propemits true false

--- The progressbar to draw ticks.
--
-- The add a little bar in between the values.
--
-- @DOC_wibox_widget_progressbar_ticks_EXAMPLE@
--
-- @property ticks
-- @tparam[opt=false] boolean ticks
-- @propemits true false
-- @see ticks_gap
-- @see ticks_size

--- The progressbar ticks gap.
--
-- @DOC_wibox_widget_progressbar_ticks_gap_EXAMPLE@
--
-- @property ticks_gap
-- @tparam[opt=1] number ticks_gap
-- @propertyunit pixel
-- @negativeallowed false
-- @propemits true false
-- @see ticks_size
-- @see ticks

--- The progressbar ticks size.
--
-- @DOC_wibox_widget_progressbar_ticks_size_EXAMPLE@
--
-- It is also possible to mix this feature with the `bar_shape` property:
--
-- @DOC_wibox_widget_progressbar_ticks_size2_EXAMPLE@
--
-- @property ticks_size
-- @tparam[opt=4] number ticks_size
-- @propertyunit pixel
-- @negativeallowed false
-- @propemits true false
-- @see ticks_gap
-- @see ticks

--- The maximum value the progressbar should handle.
--
-- By default, the value is 1. So the content of `value` is
-- a percentage.
--
-- @DOC_wibox_widget_progressbar_max_value_EXAMPLE@
--
-- @property max_value
-- @tparam[opt=1] number max_value
-- @negativeallowed true
-- @propemits true false
-- @see value

--- The progressbar background color.
--
-- @beautiful beautiful.progressbar_bg
-- @param color

--- The progressbar foreground color.
--
-- @beautiful beautiful.progressbar_fg
-- @param color

--- The progressbar shape.
--
-- @beautiful beautiful.progressbar_shape
-- @tparam[opt=gears.shape.rectangle] shape shape
-- @see gears.shape

--- The progressbar border color.
--
-- @beautiful beautiful.progressbar_border_color
-- @param color

--- The progressbar outer border width.
--
-- @beautiful beautiful.progressbar_border_width
-- @param number

--- The progressbar inner shape.
--
-- @beautiful beautiful.progressbar_bar_shape
-- @tparam[opt=gears.shape.rectangle] gears.shape shape
-- @see gears.shape

--- The progressbar bar border width.
--
-- @beautiful beautiful.progressbar_bar_border_width
-- @param number

--- The progressbar bar border color.
--
-- @beautiful beautiful.progressbar_bar_border_color
-- @param color

--- The progressbar margins.
--
-- The margins are around the progressbar. If you want to add space between the
-- bar and the border, use `paddings`.
--
-- @DOC_wibox_widget_progressbar_margins2_EXAMPLE@
--
-- Note that if the `clip` is disabled, this allows the background to be smaller
-- than the bar.
--
-- It is also possible to specify a single number instead of a border for each
-- direction;
--
-- @DOC_wibox_widget_progressbar_margins1_EXAMPLE@
--
-- @property margins
-- @tparam[opt=0] table|number|nil margins A table for each side or a number
-- @tparam[opt=0] number margins.top
-- @tparam[opt=0] number margins.bottom
-- @tparam[opt=0] number margins.left
-- @tparam[opt=0] number margins.right
-- @propertyunit pixel
-- @negativeallowed true
-- @propertytype number Use the same value for each side.
-- @propertytype table Use a different value for each side:
-- @propemits false false
-- @propbeautiful
-- @see clip
-- @see paddings
-- @see wibox.container.margin

--- The progressbar padding.
--
-- This is the space between the inner bar and the progressbar outer border.
--
-- Note that if the `clip` is disabled, this allows the bar to be taller
-- than the background.
--
-- @DOC_wibox_widget_progressbar_paddings2_EXAMPLE@
--
-- The paddings can also be a single numeric value:
--
-- @DOC_wibox_widget_progressbar_paddings1_EXAMPLE@
--
-- @property paddings
-- @tparam[opt=0] table|number|nil paddings A table for each side or a number
-- @tparam[opt=0] number paddings.top
-- @tparam[opt=0] number paddings.bottom
-- @tparam[opt=0] number paddings.left
-- @tparam[opt=0] number paddings.right
-- @propertyunit pixel
-- @negativeallowed true
-- @propertytype number Use the same value for each side.
-- @propertytype table Use a different value for each side:
-- @propemits false false
-- @propbeautiful
-- @see clip
-- @see margins

--- The progressbar margins.
--
-- Note that if the `clip` is disabled, this allows the background to be smaller
-- than the bar.
-- @beautiful beautiful.progressbar_margins
-- @tparam[opt=0] (table|number|nil) margins A table for each side or a number
-- @tparam[opt=0] number margins.top
-- @tparam[opt=0] number margins.bottom
-- @tparam[opt=0] number margins.left
-- @tparam[opt=0] number margins.right
-- @see clip
-- @see beautiful.progressbar_paddings
-- @see wibox.container.margin

--- The progressbar padding.
--
-- Note that if the `clip` is disabled, this allows the bar to be taller
-- than the background.
-- @beautiful beautiful.progressbar_paddings
-- @tparam[opt=0] (table|number|nil) padding A table for each side or a number
-- @tparam[opt=0] number paddings.top
-- @tparam[opt=0] number paddings.bottom
-- @tparam[opt=0] number paddings.left
-- @tparam[opt=0] number paddings.right
-- @see clip
-- @see beautiful.progressbar_margins


local properties = { "border_color", "color"     , "background_color",
                     "value"       , "max_value" , "ticks",
                     "ticks_gap"   , "ticks_size", "border_width",
                     "shape"       , "bar_shape" , "bar_border_width",
                     "clip"        , "margins"   , "bar_border_color",
                     "paddings",
                   }



local function describe_progressbar(w)
    local p = w._private
    if p.ticks then
        clay.ignore(w, "ticks", "are not drawn")
    end
    local bar_border_color = p.bar_border_color or beautiful.progressbar_bar_border_color
    local bar_border_width = p.bar_border_width or beautiful.progressbar_bar_border_width
        or p.border_width or beautiful.progressbar_border_width or 0
    if bar_border_color and bar_border_width > 0 then
        clay.ignore(w, "bar_border_width", "is not drawn")
    end

    local foreground = clay.solid_rgba(p.color or beautiful.progressbar_fg or "#ff0000")
    local background = clay.solid_rgba(p.background_color or beautiful.progressbar_bg or "#ff0000aa")
    local bcol = p.border_color or beautiful.progressbar_border_color
    local border = bcol and clay.solid_rgba(bcol)
    if not foreground then
        clay.ignore(w, "color", "is not solid and is transparent")
    end
    if not background then
        clay.ignore(w, "background_color", "is not solid and is transparent")
    end
    if bcol and not border then
        clay.ignore(w, "border_color", "is not solid and is transparent")
    end
    local bw = p.border_width or beautiful.progressbar_border_width or 0
    bw = border and clay.pixels(w, "border_width", bw) or 0
    local clip = p.clip ~= false and beautiful.progressbar_clip ~= false
    local margins, paddings = {}, {}
    for i, prop in ipairs { "margins", "paddings" } do
        local value = p[prop] or beautiful["progressbar_" .. prop]
        local sides = i == 1 and margins or paddings
        for j, side in ipairs { "left", "right", "top", "bottom" } do
            local v = type(value) == "number" and value or (value and value[side] or 0)
            sides[j] = clay.pixels(w, prop .. "." .. side, v)
        end
    end

    local bg_shape = p.shape or beautiful.progressbar_shape or shape.rectangle
    local radius = clay.shape_radius(bg_shape)
    if radius == nil and clip then
        clay.ignore(w, "clip", "is not cut to the shape")
        clip = false
    end
    local bar_shape = p.bar_shape or beautiful.progressbar_bar_shape or shape.rectangle
    local bar_radius = clay.shape_radius(bar_shape)
    local max = p.max_value
    local value = math.min(max, math.max(0, p.value))
    -- Clay rejects percentages over 1 (third_party/clay.h:2030-2033).
    local ratio = max > 0 and math.max(0, math.min(1, value / max)) or 0
    local bg = { w = "grow", h = "grow" }
    if radius then
        bg.bg, bg.radius = background, radius
        if bw > 0 then
            bg.border, bg.bw = border, { bw, bw, bw, bw }
        end
    else
        bg.fill, bg.stroke, bg.stroke_width = background, border, bw
        bg.shape = function(width, height)
            return clay.shape_ops(bg_shape, width - bw, height - bw, bw / 2, bw / 2)
        end
    end
    local bar
    if ratio > 0 and foreground then
        bar = { w = { percent = ratio }, h = "grow" }
        if bar_radius then
            bar.bg, bar.radius = foreground, bar_radius
        else
            bar.fill = foreground
            bar.shape = function(width, height)
                return clay.shape_ops(bar_shape, width, height)
            end
        end
    end
    -- Percent contributes no fit content (third_party/clay.h:2273), and
    -- uses its grow parent's size minus padding and gaps (:2292-2293).
    if clip then
        bg.pad = { bw + paddings[1], bw + paddings[2],
            bw + paddings[3], bw + paddings[4] }
        bg.children = { bar }
        return { w = "grow", h = "grow", pad = margins, specs = { bg } }
    end
    -- Floating grow elements take their parent's box (third_party/clay.h:2224-2237)
    -- and paint in declaration order at equal zIndex (:2603-2615).
    return { w = "grow", h = "grow", specs = {
        { float = true, w = "grow", h = "grow", pad = margins, children = { bg } },
        { float = true, w = "grow", h = "grow", pad = paddings, children = { bar } },
    } }
end

progressbar._clay = { describe = describe_progressbar }

--- Set the progressbar value.
--
-- By default, unless `max_value` is set, it is number between
-- zero and one.
--
-- @DOC_wibox_widget_progressbar_value_EXAMPLE@
--
-- @property value
-- @tparam[opt=0] number value
-- @negativeallowed true
-- @propemits true false
-- @see max_value

function progressbar:set_value(value)
    value = value or 0

    self._private.value = value

    self:emit_signal("widget::redraw_needed")
    return self
end

function progressbar:set_max_value(max_value)

    self._private.max_value = max_value

    self:emit_signal("widget::redraw_needed")
end

-- Build properties function
for _, prop in ipairs(properties) do
    if not progressbar["set_" .. prop] then
        progressbar["set_" .. prop] = function(pbar, value)
            pbar._private[prop] = value
            pbar:emit_signal("widget::redraw_needed")
            pbar:emit_signal("property::"..prop, value)
            return pbar
        end
    end
    if not progressbar["get_"..prop] then
        progressbar["get_" .. prop] = function(pbar)
            return pbar._private[prop]
        end
    end
end

--- Create a progressbar widget.
--
-- @tparam table args Standard widget() arguments. You should add width and
--  height constructor parameters to set progressbar geometry.
-- @tparam[opt] number args.width The width.
-- @tparam[opt] number args.height The height.
-- @tparam[opt] gears.color args.border_color The progressbar border color.
-- @tparam[opt] number args.border_width The progressbar border width.
-- @tparam[opt] gears.color args.bar_border_color The progressbar inner border color.
-- @tparam[opt] number args.bar_border_width The progressbar inner border width.
-- @tparam[opt] gears.color args.color The progressbar foreground color.
-- @tparam[opt] gears.color args.background_color The progressbar background color.
-- @tparam[opt] gears.shape args.bar_shape The progressbar inner shape.
-- @tparam[opt] gears.shape args.shape The progressbar shape.
-- @tparam[opt] boolean args.clip Force the inner part (the bar) to fit in the background shape.
-- @tparam[opt] boolean args.ticks The progressbar to draw ticks.
-- @tparam[opt] number args.ticks_gap The progressbar ticks gap.
-- @tparam[opt] number args.ticks_size The progressbar ticks size.
-- @tparam[opt] number args.max_value The maximum value the progressbar should handle.
-- @tparam[opt] table|number args.margins The progressbar margins.
-- @tparam[opt] table|number args.paddings The progressbar padding.
-- @tparam[opt] number args.value Set the progressbar value.
-- @treturn wibox.widget.progressbar A progressbar widget.
-- @constructorfct wibox.widget.progressbar
function progressbar.new(args)
    args = args or {}

    local pbar = base.make_widget(nil, nil, {
        enable_properties = true,
    })

    pbar._private.width     = args.width or 100
    pbar._private.height    = args.height or 20
    pbar._private.value     = 0
    pbar._private.max_value = 1

    gtable.crush(pbar, progressbar, true)

    return pbar
end

function progressbar.mt:__call(...)
    return progressbar.new(...)
end

return setmetatable(progressbar, progressbar.mt)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
