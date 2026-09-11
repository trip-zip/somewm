---------------------------------------------------------------------------
-- A layout that allows its children to take more space than what's available
-- in the surrounding container. If the content does exceed the available
-- size, a scrollbar is added and scrolling behavior enabled.
--
--@DOC_wibox_layout_defaults_overflow_EXAMPLE@
-- @author Lucas Schwiderski
-- @layoutmod wibox.layout.overflow
-- @supermodule wibox.layout.fixed
---------------------------------------------------------------------------

local base = require('wibox.widget.base')
local fixed = require('wibox.layout.fixed')
local clay = require('wibox.clay')
local gmatrix = require('gears.matrix')
local separator = require('wibox.widget.separator')
local gtable = require('gears.table')
local gshape = require('gears.shape')
local gobject = require('gears.object')
local mousegrabber = mousegrabber

local overflow = { mt = {} }


local function describe_overflow(w)
    local content, along, across = fixed.describe_linear(w)
    local p = w._private

    local scrollbar_width = clay.pixels(w, "scrollbar_width", p.scrollbar_width)

    local is_y = along == "h"
    local avail, used = p.avail_in_dir, p.used_in_dir
    local overflowing = avail and used and used > avail

    content.children, content.specs = {}, nil
    content.w, content.h = "grow", "grow"
    content.scroll = is_y and "y" or "x"
    content.scrolled = overflowing and p.scroll_factor * (used - avail) or 0
    for i, child in ipairs(p.widgets) do
        content.children[i] = { widget = child,
            [across] = p.fill_space and "grow" or nil }
    end

    -- At most the offer along the direction, as the engine's fit answers
    -- within the offered box: a fit node takes its content's size,
    -- and the drawable's root, a floating element, is clamped by nothing
    -- but its own limits (wibox.clay compile, third_party/clay.h:2224-2239).
    local node = { dir = is_y and "x" or "y", [along .. "max"] = "offer",
        specs = { content } }

    if p.scrollbar_enabled and overflowing then
        local length = math.floor(avail / used * avail)
        local position = math.floor((avail - length) * p.scroll_factor)
        local track = { [across] = scrollbar_width, [along] = "grow",
            pad = is_y and { 0, 0, position, 0 } or { position, 0, 0, 0 },
            children = { { [across] = scrollbar_width, [along] = length,
                children = clay.whole_box(p.scrollbar_widget) } } }

        p.bar_length = length
        if p.scrollbar_position == "left" or p.scrollbar_position == "top" then
            table.insert(node.specs, 1, track)
        else
            node.specs[2] = track
        end
    end

    node.solved = function(n)
        local size = is_y and "height" or "width"
        local axis = is_y and "y" or "x"
        local solved_avail, solved_used = n.box[size], 0
        local children = content.children

        if #children > 0 then
            local first, last = children[1].box, children[#children].box

            solved_used = last[axis] + last[size] - first[axis]
        end
        if solved_avail ~= p.avail_in_dir or solved_used ~= p.used_in_dir then
            p.avail_in_dir, p.used_in_dir = solved_avail, solved_used
            w:emit_signal("widget::layout_changed")
        end
    end
    return node
end

overflow._clay = { describe = describe_overflow }




--- The amount of units to advance per scroll event.
--
-- This affects calls to `scroll` and the default mouse wheel handler.
--
-- The default is `10`.
--
-- @property step
-- @tparam number step The step size.
function overflow:set_step(step)
    self._private.step = step
    -- We don't need to emit enything here, since changing step only really
    -- takes effect the next time the user scrolls
end

function overflow:get_step()
    return self._private.step
end


--- Scroll the layout's content by `amount * step`.
--
-- A positive amount scrolls down/right, a negative amount scrolls up/left.
--
-- The amount of units scrolled is affected by `step`.
--
-- @method overflow:scroll
-- @tparam number amount The amount to scroll by.
-- @emits property::overflow::scroll_factor
-- @emitstparam property::overflow::scroll_factor number scroll_factor The new
--   scroll factor.
-- @emits widget::layout_changed
-- @emits widget::redraw_needed
function overflow:scroll(amount)
    if amount == 0 then
        return
    end
    local interval = self._private.used_in_dir
    local delta = self._private.step / interval

    local factor = self._private.scroll_factor + (delta * amount)
    self:set_scroll_factor(factor)
end


--- The scroll factor.
--
-- The scroll factor represents how far the layout's content is currently
-- scrolled. It is represented as a fraction from `0` to `1`, where `0` is the
-- start of the content and `1` is the end.
--
-- @property scroll_factor
-- @tparam number scroll_factor The scroll factor.
-- @propemits true false

function overflow:set_scroll_factor(factor)
    local current = self._private.scroll_factor
    local interval = self._private.used_in_dir - self._private.avail_in_dir
    if current == factor
        -- the content takes less space than what is available, i.e. everything
        -- is already visible
        or interval <= 0
        -- the scroll factor is out of range
        or (current <= 0 and factor < 0)
        or (current >= 1 and factor > 1) then
        return
    end

    self._private.scroll_factor = math.min(1, math.max(factor, 0))

    self:emit_signal("widget::layout_changed")
    self:emit_signal("property::scroll_factor", factor)
end

function overflow:get_scroll_factor()
    return self._private.scroll_factor
end


--- The scrollbar width.
--
-- For horizontal scrollbars, this is the scrollbar height
--
-- The default is `5`.
--
--@DOC_wibox_layout_overflow_scrollbar_width_EXAMPLE@
--
-- @property scrollbar_width
-- @tparam number scrollbar_width The scrollbar width.
-- @propemits true false

function overflow:set_scrollbar_width(width)
    if self._private.scrollbar_width == width then
        return
    end

    self._private.scrollbar_width = width

    self:emit_signal("widget::layout_changed")
    self:emit_signal("property::scrollbar_width", width)
end

function overflow:get_scrollbar_width()
    return self._private.scrollbar_width
end


--- The scrollbar position.
--
-- For horizontal scrollbars, this can be `"top"` or `"bottom"`,
-- for vertical scrollbars this can be `"left"` or `"right"`.
-- The default is `"right"`/`"bottom"`.
--
--@DOC_wibox_layout_overflow_scrollbar_position_EXAMPLE@
--
-- @property scrollbar_position
-- @tparam string scrollbar_position The scrollbar position.
-- @propemits true false

function overflow:set_scrollbar_position(position)
    if self._private.scrollbar_position == position then
        return
    end

    self._private.scrollbar_position = position

    self:emit_signal("widget::layout_changed")
    self:emit_signal("property::scrollbar_position", position)
end

function overflow:get_scrollbar_position()
    return self._private.scrollbar_position
end


--- The scrollbar visibility.
--
-- If this is set to `false`, no scrollbar will be rendered, even if the layout's
-- content overflows. Mouse wheel scrolling will work regardless.
--
-- The default is `true`.
--
-- @property scrollbar_enabled
-- @tparam boolean scrollbar_enabled The scrollbar visibility.
-- @propemits true false

function overflow:set_scrollbar_enabled(enabled)
    if self._private.scrollbar_enabled == enabled then
        return
    end

    self._private.scrollbar_enabled = enabled

    self:emit_signal("widget::layout_changed")
    self:emit_signal("property::scrollbar_enabled", enabled)
end

function overflow:get_scrollbar_enabled()
    return self._private.scrollbar_enabled
end

-- Wraps a callback function for `mousegrabber` that is capable of
-- updating the scroll factor.
local function build_grabber(container, initial_x, initial_y, geo)
    local is_y = container._private.dir == "y"
    local bar_interval = container._private.avail_in_dir - container._private.bar_length
    local start_pos = container._private.scroll_factor * bar_interval
    local start = is_y and initial_y or initial_x

    -- Calculate a matrix transforming from screen coordinates into widget
    -- coordinates.
    -- This is required for mouse movement to work when the widget has been
    -- transformed by something like `wibox.container.rotate`.
    local wgeo = geo.drawable.drawable:geometry()
    local matrix = gmatrix.create_translate(-wgeo.x - geo.x, -wgeo.y - geo.y)

    return function(mouse)
        if not mouse.buttons[1] then
            return false
        end

        local x, y = matrix:transform_point(mouse.x, mouse.y)
        local pos = is_y and y or x
        container:set_scroll_factor((start_pos + (pos - start)) / bar_interval)

        return true
    end
end

-- Applies a mouse button signal using `build_grabber` to a scrollbar widget.
local function apply_scrollbar_mouse_signal(container, w)
    w:connect_signal('button::press', function(_, x, y, button_id, _, geo)
        if button_id ~= 1 then
            return
        end
        mousegrabber.run(build_grabber(container, x, y, geo), "fleur")
    end)
end


--- The scrollbar widget.
-- This widget is rendered as the scrollbar element.
--
-- The default is `wibox.widget.separator{ shape = gears.shape.rectangle }`.
--
--@DOC_wibox_layout_overflow_scrollbar_widget_EXAMPLE@
--
-- @property scrollbar_widget
-- @tparam widget scrollbar_widget The scrollbar widget.
-- @propemits true false

function overflow:set_scrollbar_widget(widget)
    local w = base.make_widget_from_value(widget)

    apply_scrollbar_mouse_signal(self, w)

    self._private.scrollbar_widget = w

    self:emit_signal("widget::layout_changed")
    self:emit_signal("property::scrollbar_widget", widget)
end

function overflow:get_scrollbar_widget()
    return self._private.scrollbar_widget
end


function overflow:reset()
    self._private.widgets = {}
    self._private.scroll_factor = 0

    local scrollbar_widget = separator({ shape = gshape.rectangle })
    apply_scrollbar_mouse_signal(self, scrollbar_widget)
    self._private.scrollbar_widget = scrollbar_widget

    self:emit_signal("widget::layout_changed")
    self:emit_signal("widget::reset")
    self:emit_signal("widget::reseted")
end

local function new(dir, ...)
    local ret = fixed[dir](...)

    gtable.crush(ret, overflow, true)
    ret.widget_name = gobject.modulename(2)
    -- Tell the widget system to prevent clicks outside the layout's extends
    -- to register with child widgets, even if they actually extend that far.
    -- This prevents triggering button presses on hidden/clipped widgets.
    ret.clip_child_extends = true

    -- Manually set the scroll factor here. We don't know the bounding size yet.
    ret._private.scroll_factor = 0

    -- Apply defaults. Bypass setters to avoid signals.
    ret._private.step = 10
    ret._private.fill_space = true
    ret._private.scrollbar_width = 5
    ret._private.scrollbar_enabled = true
    ret._private.scrollbar_position = dir == "vertical" and "right" or "bottom"

    local scrollbar_widget = separator({ shape = gshape.rectangle })
    apply_scrollbar_mouse_signal(ret, scrollbar_widget)
    ret._private.scrollbar_widget = scrollbar_widget

    ret:connect_signal('button::press', function(self, _, _, button)
        if button == 4 then
            self:scroll(-1)
        elseif button == 5 then
            self:scroll(1)
        end
    end)

    return ret
end


--- Returns a new horizontal overflow layout.
-- Child widgets are placed similar to `wibox.layout.fixed`, except that
-- they may take as much width as they want. If the total width of all child
-- widgets exceeds the width available whithin the layout's outer container
-- a scrollbar will be added and scrolling behavior enabled.
-- @tparam widget ... Widgets that should be added to the layout.
-- @constructorfct wibox.layout.overflow.horizontal
function overflow.horizontal(...)
    return new("horizontal", ...)
end


--- Returns a new vertical overflow layout.
-- Child widgets are placed similar to `wibox.layout.fixed`, except that
-- they may take as much height as they want. If the total height of all child
-- widgets exceeds the height available whithin the layout's outer container
-- a scrollbar will be added and scrolling behavior enabled.
-- @tparam widget ... Widgets that should be added to the layout.
-- @constructorfct wibox.layout.overflow.vertical
function overflow.vertical(...)
    return new("vertical", ...)
end

return setmetatable(overflow, overflow.mt)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
