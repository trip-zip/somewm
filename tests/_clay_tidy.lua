-- Fixtures for the accepted tidy-tree texts. Expectations are never recorded.
local awful = require('awful')
local wibox = require('wibox')
local clay = require('wibox.clay')
local example = require('_clay_example')
local M = {}

function M.leaf(width, height, color)
    local widget = wibox.widget.base.make_widget(nil, nil, {enable_properties=true})
    clay.describe_widget(widget, function()
        return { wmin = width, hmin = height, bg = clay.solid_rgba(color) }
    end, 'wibox.widget.base')
    return widget
end

function M.popup(widget)
    return awful.popup { screen = screen[1], visible = true, ontop = true,
        placement = awful.placement.top_left, offset = {x=100, y=100},
        border_width = 1, border_color = '#ffffff',
        bg = '#204080', shadow = false, widget = widget }
end

function M.run(cases)
    local checks = example.batch()
    local steps, state, previous = {}, nil, nil
    steps[#steps + 1] = function()
        assert(screen[1].geometry.width == 1280 and screen[1].geometry.height == 720)
        require('beautiful').font = 'monospace 10'
        return true
    end
    for _, case in ipairs(cases) do
        steps[#steps + 1] = function()
            state = case.create()
            assert(state.popup, case.name .. ' has no fixture popup')
            previous = nil
            return true
        end
        steps[#steps + 1] = function(n)
            local dump = awesome._clay_tree(screen[1])
            if n < 3 or previous ~= dump then
                previous = dump
                assert(n < 30, case.name .. ' did not settle:\n' .. dump)
                return
            end
            -- Old unsupported grid cases still have a real host declaration.
            -- Compare that actual tree, not a missing-hook exception.
            assert(dump:find('  POPUP ', 1, true), 'fixture host is not declared')
            if checks.check(case.name, dump) and case.verify then
                case.verify(state, dump)
            end
            return true
        end
        steps[#steps + 1] = function()
            state.popup.visible = false
            if state.cleanup then state.cleanup() end
            state = nil
            return true
        end
    end
    steps[#steps + 1] = checks.finish
    require('_runner').run_steps(steps)
end

return M
