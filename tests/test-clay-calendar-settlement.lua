-- Observe the current calendar generation through normal frame dispatch.
local runner = require('_runner')
local async = require('_async')
local wibox = require('wibox')
local awful = require('awful')
local clay = require('wibox.clay')
local check = require('_clay_grid_presentation')
local solver = dofile('tests/_grid_solver.lua')
local example = require('_clay_example')
local pointer = assert(require('_utils').binary_or_skip('./build-test/test-virtual-pointer-client'))

local function frames()
    return assert(tonumber(awesome._clay_tree(screen[1]):match('^[^\n]- frames (%d+) passes ')))
end

runner.run_async(function()
    local host, calendar, day
    local compiles, declarations = 0, 0
    local original = clay.compile
    clay.compile = function(...)
        compiles = compiles + 1
        return original(...)
    end
    awesome.connect_signal('clay::declare', function() declarations = declarations + 1 end)
    local function transition(label, action)
        local before, frame = compiles, frames()
        action()
        assert(async.wait_for_condition(function()
            local d = host._drawable
            local cache = d._clay_cache
            if compiles == before or not d._clay_tree or not cache
                    or next(cache.stale) or cache.width ~= host.width
                    or cache.height ~= host.height or frames() <= frame then
                return false
            end
            local settled = true
            local function walk(n)
                for _, binding in clay.bindings(n) do
                    if binding.grid_state and not binding.grid_state.settled then settled = false end
                end
                for _, child in ipairs(n.children or {}) do walk(child) end
            end
            walk(d._clay_tree)
            return settled
        end, 2, .001), label .. ': current generation did not reach presentation')
        check(host._drawable)
        local idle = declarations
        async.sleep(.01)
        assert(declarations == idle, label .. ': late declaration after settlement')
        async.sleep(.25)
        assert(declarations == idle, label .. ': idle declaration')
        local found = solver.find(host._drawable._clay_tree, day)[1]
        assert(found)
        local b = found.box
        example.pixel(host.x + b.x + 1, host.y + b.y + 1, '#d03020')
        local pressed, released = 0, 0
        local function press(_, x, y, button, _, area)
            assert(x == 1 and y == 1 and button == 1 and area.occurrence == found.binding.id)
            pressed = pressed + 1
        end
        local function release() released = released + 1 end
        day:connect_signal('button::press', press)
        day:connect_signal('button::release', release)
        awful.spawn{pointer, 'click', tostring(host.x + b.x + 1), tostring(host.y + b.y + 1), '1280', '720', 'left'}
        assert(async.wait_for_condition(function() return pressed == 1 and released == 1 end, 2, .01))
        day:disconnect_signal('button::press', press)
        day:disconnect_signal('button::release', release)
        -- The click left the pointer over the calendar. The pointer image is
        -- a leaf of the tree, so a later transition that moves the calendar
        -- out from under it would change the image, a frame of its own; park
        -- the pointer over the root and let that frame land first.
        awful.spawn{pointer, 'move', '1200', '700', '1280', '720'}
        async.sleep(.1)
        io.stderr:write('[SETTLEMENT] ' .. label .. ' current=true presented=true idle=true input=true\n')
    end
    for _, colors in ipairs{'#ffffff', {inner = '#ffffff80', outer = '#00ffffc0'}} do
        transition('month-cold', function()
            calendar = wibox.widget.calendar.month(nil, 'monospace 10')
            calendar.spacing = 3
            calendar.week_numbers = true
            calendar.border_width = 1
            calendar.border_color = colors
            calendar.fn_embed = function(child, flag, date)
                if flag == 'normal' and date.day == 1 then
                    day = wibox.container.background(child, '#d03020')
                    return day
                end
                return child
            end
            calendar.date = {year = 2026, month = 9, day = 16}
            host = awful.popup{screen = screen[1], x = 10, y = 10, visible = true, widget = calendar, maximum_width = 1100}
        end)
        transition('font-grow', function() calendar.font = 'monospace 14' end)
        transition('font-restore', function() calendar.font = 'monospace 10' end)
        transition('width-grow', function() calendar.forced_width = 900 end)
        transition('width-restore', function() calendar.forced_width = nil end)
        local title = day.widget
        local text = title.text
        transition('content-grow', function() title.text = 'one one one' end)
        transition('content-restore', function() title.text = text end)
        host.visible = false
    end
    clay.compile = original
    runner.done()
end)
