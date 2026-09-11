---------------------------------------------------------------------------
-- This container scrolls its inner widget inside of the available space. An
-- example usage would be a text widget that displays information about the
-- currently playing song without using too much space for long song titles.
--
-- Please note that mouse events do not propagate to widgets inside of the
-- scroll container. Also, if this widget is causing too high CPU usage, you can
-- use @{set_fps} to make it update less often.
-- @usage
-- wibox.widget {
--    layout = wibox.container.scroll.horizontal,
--    max_size = 100,
--    step_function = wibox.container.scroll.step_functions
--                    .waiting_nonlinear_back_and_forth,
--    speed = 100,
--    {
--        widget = wibox.widget.textbox,
--        text = "This is a " .. string.rep("very, ", 10) ..  " very long text",
--    },
-- }
-- @author Uli Schlachter (based on ideas from Saleur Geoffrey)
-- @copyright 2015 Uli Schlachter
-- @containermod wibox.container.scroll
-- @supermodule wibox.widget.base
---------------------------------------------------------------------------

local base = require("wibox.widget.base")
local gtable = require("gears.table")
local lgi = require("lgi")
local GLib = lgi.GLib

local scroll = {}







--- Pause the scrolling animation.
-- @method pause
-- @noreturn
-- @see continue
function scroll:pause()
    if self._private.paused then
        return
    end
    self._private.paused = true
    self._private.timer:stop()
end

--- Continue the scrolling animation.
-- @method continue
-- @noreturn
-- @see pause
function scroll:continue()
    if not self._private.paused then
        return
    end
    self._private.paused = false
    self._private.timer:continue()
    self:emit_signal("widget::redraw_needed")
end

--- Reset the scrolling state to its initial condition.
-- For must scroll step functions, the effect of this function should be to
-- display the widget without any scrolling applied.
-- This function does not undo the effect of @{pause}.
-- @method reset_scrolling
-- @noreturn
function scroll:reset_scrolling()
    self._private.timer:start()
    if self._private.paused then
        self._private.timer:stop()
    end
end

--- Set the direction in which this widget scroll.
-- @method set_direction
-- @param dir Either "h" for horizontal scrolling or "v" for vertical scrolling
-- @noreturn
function scroll:set_direction(dir)
    if dir == self._private.dir then
        return
    end
    if dir ~= "h" and dir ~= "v" then
        error("Invalid direction, can only be 'h' or 'v'")
    end
    self._private.dir = dir
    self:emit_signal("widget::layout_changed")
    self:emit_signal("widget::redraw_needed")
end

--- The widget to be scrolled.
-- @property widget
-- @tparam[opt=nil] widget|nil widget

function scroll:set_widget(widget)
    if widget == self._private.widget then
        return
    end

    local w = base.make_widget_from_value(widget)

    if w then
        base.check_widget(w)
    end

    self._private.widget = w
    self:emit_signal("widget::layout_changed")
    self:emit_signal("widget::redraw_needed")
end

function scroll:get_widget()
    return self._private.widget
end

function scroll:get_children()
    return {self._private.widget}
end

function scroll:set_children(children)
    self:set_widget(children[1])
end

--- Specify the expand mode that is used for extra space.
-- @method set_expand
-- @tparam boolean expand If true, the widget is expanded to include the extra
-- space. If false, the extra space is simply left empty.
-- @noreturn
-- @see set_extra_space
function scroll:set_expand(expand)
    if expand == self._private.expand then
        return
    end
    self._private.expand = expand
    self:emit_signal("widget::redraw_needed")
end

--- Set the number of frames per second that this widget should draw.
-- @method set_fps
-- @tparam number fps The number of frames per second
-- @noreturn
function scroll:set_fps(fps)
    if fps == self._private.fps then
        return
    end
    self._private.fps = fps
    -- No signal needed: If we are scrolling, the next redraw will apply the new
    -- FPS, else it obviously doesn't make a difference.
end

--- Set the amount of extra space that should be included in the scrolling. This
-- extra space will likely be left empty between repetitions of the widgets.
-- @method set_extra_space
-- @tparam number extra_space The amount of extra space
-- @noreturn
-- @see set_expand
function scroll:set_extra_space(extra_space)
    if extra_space == self._private.extra_space then
        return
    end
    self._private.extra_space = extra_space
    self:emit_signal("widget::redraw_needed")
end

--- Set the speed of the scrolling animation. The exact meaning depends on the
-- step function that is used, but for the simplest step functions, this will be
-- in pixels per second.
-- @method set_speed
-- @tparam number speed The speed for the animation
-- @noreturn
function scroll:set_speed(speed)
    if speed == self._private.speed then
        return
    end
    self._private.speed = speed
    self:emit_signal("widget::redraw_needed")
end

--- Set the maximum size of this widget in the direction set by
-- @{set_direction}. If the child widget is smaller than this size, no scrolling
-- is done. If the child widget is larger, then only this size will be visible
-- and the rest is made visible via scrolling.
-- @method set_max_size
-- @tparam number max_size The maximum size of this widget or nil for unlimited.
-- @noreturn
function scroll:set_max_size(max_size)
    if max_size == self._private.max_size then
        return
    end
    self._private.max_size = max_size
    self:emit_signal("widget::layout_changed")
end

--- Set the step function that determines the exact behaviour of the scrolling
-- animation.
-- The step function is called with five arguments:
--
-- * The time in seconds since the state of the animation
-- * The size of the child widget
-- * The size of the visible part of the widget
-- * The speed of the animation. This should have a linear effect on this
--   function's behaviour.
-- * The extra space configured by @{set_extra_space}. This was not yet added to
--   the size of the child widget, but should likely be added to it in most
--   cases.
--
-- The step function should return a single number. This number is the offset at
-- which the widget is drawn and should be between 0 and `size+extra_space`.
-- @method set_step_function
-- @tparam function step_function A step function.
-- @noreturn
-- @see step_functions
function scroll:set_step_function(step_function)
    -- Call the step functions once to see if it works
    step_function(0, 42, 10, 10, 5)
    if step_function == self._private.step_function then
        return
    end
    self._private.step_function = step_function
    self:emit_signal("widget::redraw_needed")
end

--- Set an upper limit for the space for scrolling.
-- This restricts the child widget's maximal size.
-- @method set_space_for_scrolling
-- @tparam number space_for_scrolling The space for scrolling
-- @noreturn
function scroll:set_space_for_scrolling(space_for_scrolling)
    if space_for_scrolling == self._private.space_for_scrolling then
        return
    end
    self._private.space_for_scrolling = space_for_scrolling
    self:emit_signal("widget::layout_changed")
end

local function get_layout(dir, widget, fps, speed, extra_space, expand, max_size, step_function, space_for_scrolling)
    local ret = base.make_widget(nil, nil, {enable_properties = true})

    ret._private.paused = false
    ret._private.timer = GLib.Timer()
    ret._private.scroll_timer = nil

    gtable.crush(ret, scroll, true)

    ret:set_direction(dir)
    ret:set_widget(widget)
    ret:set_fps(fps or 20)
    ret:set_speed(speed or 10)
    ret:set_extra_space(extra_space or 0)
    ret:set_expand(expand)
    ret:set_max_size(max_size)
    ret:set_step_function(step_function or scroll.step_functions.linear_increase)
    ret:set_space_for_scrolling(space_for_scrolling or 2^1024)

    return ret
end

--- Get a new horizontal scrolling container.
-- @constructorfct wibox.container.scroll.horizontal
-- @param[opt] widget The widget that should be scrolled
-- @param[opt=20] fps The number of frames per second
-- @param[opt=10] speed The speed of the animation
-- @param[opt=0] extra_space The amount of extra space to include
-- @tparam[opt=false] boolean expand Should the widget be expanded to include the
-- extra space?
-- @param[opt] max_size The maximum size of the child widget
-- @param[opt=step_functions.linear_increase] step_function The step function to be used
-- @param[opt=2^1024] space_for_scrolling The space for scrolling
function scroll.horizontal(widget, fps, speed, extra_space, expand, max_size, step_function, space_for_scrolling)
    return get_layout("h", widget, fps, speed, extra_space, expand, max_size, step_function, space_for_scrolling)
end

--- Get a new vertical scrolling container.
-- @constructorfct wibox.container.scroll.vertical
-- @param[opt] widget The widget that should be scrolled
-- @param[opt=20] fps The number of frames per second
-- @param[opt=10] speed The speed of the animation
-- @param[opt=0] extra_space The amount of extra space to include
-- @tparam[opt=false] boolean expand Should the widget be expanded to include the
-- extra space?
-- @param[opt] max_size The maximum size of the child widget
-- @param[opt=step_functions.linear_increase] step_function The step function to be used
-- @param[opt=2^1024] space_for_scrolling The space for scrolling
function scroll.vertical(widget, fps, speed, extra_space, expand, max_size, step_function, space_for_scrolling)
    return get_layout("v", widget, fps, speed, extra_space, expand, max_size, step_function, space_for_scrolling)
end

--- A selection of step functions
-- @see set_step_function
scroll.step_functions = {}

--- A step function that scrolls the widget in an increasing direction with
-- constant speed.
-- @callback scroll.step_functions.linear_increase
function scroll.step_functions.linear_increase(elapsed, size, _, speed, extra_space)
    return (elapsed * speed) % (size + extra_space)
end

--- A step function that scrolls the widget in an decreasing direction with
-- constant speed.
-- @callback scroll.step_functions.linear_decrease
function scroll.step_functions.linear_decrease(elapsed, size, _, speed, extra_space)
    return (-elapsed * speed) % (size + extra_space)
end

--- A step function that scrolls the widget to its end and back to its
-- beginning, then back to its end, etc. The speed is constant.
-- @callback scroll.step_functions.linear_back_and_forth
function scroll.step_functions.linear_back_and_forth(elapsed, size, visible_size, speed)
    local state = ((elapsed * speed) % (2 * size)) / size
    state = state <= 1 and state or 2 - state
    return (size - visible_size) * state
end

--- A step function that scrolls the widget to its end and back to its
-- beginning, then back to its end, etc. The speed is null at the ends and
-- maximal in the middle.
-- @callback scroll.step_functions.nonlinear_back_and_forth
function scroll.step_functions.nonlinear_back_and_forth(elapsed, size, visible_size, speed)
    local state = ((elapsed * speed) % (2 * size)) / size
    local negate = false
    if state > 1 then
        negate = true
        state = state - 1
    end
    if state < 1/3 then
        -- In the first 1/3rd of time, do a quadratic increase in speed
        state = 2 * state * state
    elseif state < 2/3 then
        -- In the center, do a linear increase. That means we need:
        -- If state is 1/3, result is 2/9 = 2 * 1/3 * 1/3
        -- If state is 2/3, result is 7/9 = 1 - 2 * (1 - 2/3) * (1 - 2/3)
        state = 5/3*state - 3/9
    else
        -- In the last 1/3rd of time, do a quadratic decrease in speed
        state = 1 - 2 * (1 - state) * (1 - state)
    end
    if negate then
        state = 1 - state
    end
    return (size - visible_size) * state
end

--- A step function that scrolls the widget to its end and back to its
-- beginning, then back to its end, etc. The speed is null at the ends and
-- maximal in the middle. At both ends the widget stands still for a moment.
-- @callback scroll.step_functions.waiting_nonlinear_back_and_forth
function scroll.step_functions.waiting_nonlinear_back_and_forth(elapsed, size, visible_size, speed)
    local state = ((elapsed * speed) % (2 * size)) / size
    local negate = false
    if state > 1 then
        negate = true
        state = state - 1
    end
    if state < 1/5 or state > 4/5 then
        -- One fifth of time, nothing moves
        state = state < 1/5 and 0 or 1
    else
        state = (state - 1/5) * 5/3
        if state < 1/3 then
            -- In the first 1/3rd of time, do a quadratic increase in speed
            state = 2 * state * state
        elseif state < 2/3 then
            -- In the center, do a linear increase. That means we need:
            -- If state is 1/3, result is 2/9 = 2 * 1/3 * 1/3
            -- If state is 2/3, result is 7/9 = 1 - 2 * (1 - 2/3) * (1 - 2/3)
            state = 5/3*state - 3/9
        else
            -- In the last 1/3rd of time, do a quadratic decrease in speed
            state = 1 - 2 * (1 - state) * (1 - state)
        end
    end
    if negate then
        state = 1 - state
    end
    return (size - visible_size) * state
end

return scroll

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
