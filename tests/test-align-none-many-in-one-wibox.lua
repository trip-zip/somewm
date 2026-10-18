-- An align with expand = "none" cuts each outer widget at its half. The cut
-- is the renderer's, so it spends none of the output's 100 scrolling
-- records: 51 of them in one wibox, 102 halves, are still drawn.
local runner = require('_runner')
local async = require('_async')
local wibox = require('wibox')
local s = screen[1]

local rows = 51

local function text(name, i)
    return wibox.widget.textbox(name .. i)
end

local function box(dump, name)
    local x, w = dump:match('text "' .. name .. '" font=%d+ box (%-?%d+),%-?%d+ (%d+)x%d+')
    return tonumber(x), tonumber(w)
end

runner.run_async(function()
    local stack = wibox.layout.fixed.vertical()
    for i = 1, rows do
        stack:add(wibox.widget {
            text('L', i), text('M', i), text('R', i),
            expand = 'none',
            layout = wibox.layout.align.horizontal,
        })
    end
    local host = wibox {screen = s, x = s.geometry.x + 40, y = s.geometry.y + 40,
        width = 400, height = rows * 14, visible = true, widget = stack}

    local dump
    assert(async.wait_for_condition(function()
        dump = awesome._clay_tree(s)
        return dump:find("over the output's element budget", 1, true) or box(dump, 'M' .. rows)
    end, 2, .01), 'the wibox never solved')
    assert(not dump:find("over the output's element budget", 1, true),
        rows .. ' aligns with expand none are refused:\n' .. dump)

    local left = host.x - s.geometry.x
    local lx, lw = box(dump, 'L' .. rows)
    local mx, mw = box(dump, 'M' .. rows)
    local rx, rw = box(dump, 'R' .. rows)
    assert(lx == left and lx + lw <= mx and mx + mw <= rx and rx + rw == left + host.width,
        string.format('row %d is not left, middle, right: %d+%d %d+%d %d+%d', rows, lx, lw, mx, mw, rx, rw))
    local off = math.abs(mx + mw / 2 - (left + host.width / 2))
    assert(off <= 1, string.format('the middle is %.1f px off centre', off))

    host.visible = false
    runner.done()
end)
