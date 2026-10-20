-- timeout: 35
local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local wibox = require('wibox')
local capture = require('_widget_capture')
local s = screen[1]

local function wait(test, why)
    assert(async.wait_for_condition(test, 5, .02), why)
end
local function cursor_width()
    return tonumber(awesome._clay_tree(s):match('\n  cursor %S+ w=fixed%((%d+)%)'))
end

runner.run_async(function()
    mouse.coords {x = 400, y = 300}
    mouse._fake_motion(1, 0)
    mouse._fake_motion(-1, 0)
    local original_size = root.cursor_size()
    root.cursor_size(48)
    async.sleep(.1)
    local base = cursor_width()
    assert(base and base > 0)
    local under = wibox {x = 250, y = 150, width = 400, height = 300,
        visible = true, bg = '#102030'}
    local a = awful.accessibility {
        cursor_finder_effect = 'both', cursor_finder_animated = false,
        cursor_finder_duration = 30, cursor_finder_deflate_delay = 30,
    }
    a:find_cursor()
    assert(root._cursor_magnify() == 3, 'static enlargement was not immediate')
    wait(function() return cursor_width() and math.abs(cursor_width() - base * 3) <= 2 end,
        'magnification did not multiply the configured base size')
    wait(function() return a._private.ring_timer and a._private.ring_timer.started end,
        'static ring lifetime did not start')
    assert(mouse.current_wibox == under, 'static rings intercepted input')
    local shot = capture.new(s, 290, 190, 220, 220)
    local before = shot:shot()
    assert(before:find(string.char(0, 102, 255, 255), 1, true), 'static rings were not painted')
    async.sleep(.3)
    assert(shot:shot() == before, 'static rings changed size or opacity')
    local x = a._private.overlay.x
    mouse._fake_motion(20, 0)
    assert(a._private.overlay.x == x + 20, 'static rings did not follow the pointer')
    a:find_cursor()
    assert(root._cursor_magnify() == 4, 'static repeat did not increase magnification')
    a:stop_cursor_finder()
    assert(not a._private.overlay.visible and root._cursor_magnify() == 1)
    wait(function() return cursor_width() == base end, 'cancellation did not restore the larger base cursor')
    assert(root.cursor_size() == 48, 'locator changed the configured base size')

    -- Repeated activation replaces both lifetimes; expired callbacks cannot
    -- hide the new rings or restore the cursor before their new deadlines.
    a.cursor_finder_duration = .8
    a.cursor_finder_deflate_delay = .8
    a:find_cursor()
    wait(function() return a._private.ring_timer and a._private.ring_timer.started end,
        'static ring lifetime did not restart')
    async.sleep(.2)
    a.cursor_finder_duration = 1.5
    a.cursor_finder_deflate_delay = 1.5
    a:find_cursor()
    async.sleep(.7)
    assert(a._private.overlay.visible and root._cursor_magnify() == 4,
        'retrigger did not extend the static locator')
    wait(function() return not a._private.overlay.visible and root._cursor_magnify() == 1 end,
        'static locator did not expire')
    wait(function() return cursor_width() == base end, 'expiration did not restore the larger base cursor')
    a:find_cursor()
    a:stop_cursor_finder()
    async.sleep(.1)
    assert(not a._private.overlay.visible, 'cancelled static rings restarted')
    under.visible = false
    root.cursor_size(original_size)
    runner.done()
end)
