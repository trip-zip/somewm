-- luacheck: globals screen awesome
-- A slider has no content width. As the last widget along a fixed row it
-- takes what the row leaves, as its fit did in 2.0, here inside an align
-- with expand = "none" as a volume OSD lays it out.
local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local wibox = require('wibox')
local s = screen[1]

local WIDTH, PAD, ICON, GAP = 300, 24, 24, 24

local function osd_widget()
    local slider = wibox.widget {
        value = 50, maximum = 100, bar_height = 2, handle_width = 15,
        bar_color = '#808080', handle_color = '#ffffff',
        widget = wibox.widget.slider,
    }
    local row = wibox.widget {
        {forced_width = ICON, forced_height = ICON, bg = '#ff0000',
            widget = wibox.container.background},
        {nil, slider, nil, expand = 'none', layout = wibox.layout.align.vertical},
        spacing = GAP,
        layout = wibox.layout.fixed.horizontal,
    }
    return {
        {
            {wibox.widget.textbox('Volume'), nil, wibox.widget.textbox('0%'),
                expand = 'none', forced_height = 48, layout = wibox.layout.align.horizontal},
            row,
            layout = wibox.layout.fixed.vertical,
        },
        left = PAD, right = PAD,
        widget = wibox.container.margin,
    }
end

local function slider_width()
    local w = awesome._clay_tree(s):match('wibox%.widget%.slider[^\n]* box %-?%d+,%-?%d+ (%d+)x%d+')
    return tonumber(w)
end

local function check(name, host)
    local w
    assert(async.wait_for_condition(function()
        w = slider_width()
        return w ~= nil
    end, 2, .01), name .. ': the slider never solved:\n' .. awesome._clay_tree(s))
    local want = WIDTH - 2 * PAD - ICON - GAP
    assert(w == want, string.format('%s: the slider is %d wide, not the %d the row leaves:\n%s',
        name, w, want, awesome._clay_tree(s)))
    io.stderr:write(string.format('[PASS] %s: the slider is %d wide\n', name, w))
    host.visible = false
    assert(async.wait_for_condition(function() return slider_width() == nil end, 2, .01),
        name .. ': the slider stayed in the tree after hiding')
end

runner.run_async(function()
    check('wibox', wibox {screen = s, x = s.geometry.x + 40, y = s.geometry.y + 40,
        width = WIDTH, height = 100, visible = true, widget = wibox.widget(osd_widget())})

    check('popup', awful.popup {screen = s, x = s.geometry.x + 40, y = s.geometry.y + 40,
        width = WIDTH, height = 100, maximum_width = WIDTH, maximum_height = 100,
        ontop = true, visible = true, widget = osd_widget()})

    runner.done()
end)
