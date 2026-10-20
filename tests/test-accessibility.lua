-- timeout: 35
local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local beautiful = require('beautiful')
local wibox = require('wibox')
local capture = require('_widget_capture')
local s = screen[1]

local function cursor_box()
    local dump = awesome._clay_tree(s)
    local w, h, x, y = dump:match('\n  cursor %S+ w=fixed%((%d+)%) %a+ h=fixed%((%d+)%) %a+ attach ROOT offset (%-?%d+),(%-?%d+)')
    assert(w, dump)
    return {w = tonumber(w), h = tonumber(h), x = tonumber(x), y = tonumber(y)}
end
local function move(x, y)
    mouse.coords {x = x, y = y}
    mouse._fake_motion(1, 0)
    mouse._fake_motion(-1, 0)
end
local function wait(test, why)
    assert(async.wait_for_condition(test, 3, .02), why)
end

runner.run_async(function()
    move(400, 300)
    async.sleep(.1)
    local normal = cursor_box()
    local a = awful.accessibility {
        cursor_finder_effect = 'magnify', cursor_finder_inflate_duration = .2,
        cursor_finder_deflate_delay = 30, cursor_finder_deflate_duration = .2,
    }
    local starts, ends, changes = 0, 0, 0
    a:connect_signal('cursor_finder::start', function() starts = starts + 1 end)
    a:connect_signal('cursor_finder::end', function() ends = ends + 1 end)
    a:connect_signal('property::cursor_finder_enabled', function() changes = changes + 1 end)
    a.cursor_finder_enabled = false
    a:find_cursor()
    assert(starts == 0 and not a.cursor_finder_enabled, 'false must override the enabled default')
    a.cursor_finder_enabled = true
    assert(changes == 2)
    beautiful.accessibility_cursor_finder_radius = 75
    assert(a.cursor_finder_radius == 75)
    a.cursor_finder_radius = 50
    assert(a.cursor_finder_radius == 50)
    a.cursor_finder_radius = nil
    assert(a.cursor_finder_radius == 75)
    beautiful.accessibility_cursor_finder_radius = nil
    for key, value in pairs {cursor_finder_max_scale = math.huge,
        cursor_finder_duration = -1, cursor_finder_ring_count = 2.5,
        cursor_finder_effect = 'invalid'} do
        assert(not pcall(function() a[key] = value end), 'invalid property accepted: ' .. key)
    end
    assert(not pcall(root._cursor_magnify, 0 / 0))
    assert(not pcall(root._cursor_magnify, 2, math.huge))

    a:find_cursor()
    assert(root._cursor_magnify() < 3, 'inflation snapped to target')
    wait(function() return root._cursor_magnify() == 3 end, 'inflation did not settle')
    wait(function() return math.abs(cursor_box().w - normal.w * 3) <= 2 end,
        'cursor did not grow threefold')
    local grown = cursor_box()
    move(600, 400)
    wait(function()
        local moved = cursor_box()
        return moved.x == grown.x + 200 and moved.y == grown.y + 100
    end, 'enlarged cursor did not preserve its hotspot while moving')
    a:find_cursor()
    wait(function() return root._cursor_magnify() == 4 end, 'repeat did not increase magnification')
    a.cursor_finder_deflate_delay = .3
    a:find_cursor()
    assert(starts == 1, 'retrigger emitted a second start')
    wait(function() return ends == 1 end, 'locator did not finish')
    assert(root._cursor_magnify() == 1, 'deflation left an enlarged cursor')
    async.sleep(.04)
    assert(cursor_box().w == normal.w)

    -- Straight motion is not a shake, but alternating long segments are.
    a.cursor_finder_cooldown = 0
    a.cursor_finder_shake_enabled = true
    async.sleep(.55)
    for _ = 1, 15 do mouse._fake_motion(4, 0) end
    assert(starts == 1, 'straight motion triggered a shake')
    for _ = 1, 6 do mouse._fake_motion(-120, 0); mouse._fake_motion(120, 0) end
    wait(function() return starts == 2 end, 'shake motion did not trigger the locator')
    a.cursor_finder_shake_enabled = false
    a:stop_cursor_finder()
    assert(ends == 2 and root._cursor_magnify() == 1)

    -- A new instance takes over the single pointer and ends its old locator.
    a:find_cursor()
    local b = awful.accessibility {cursor_finder_effect = 'magnify'}
    b:find_cursor()
    assert(ends == 3)
    a:stop_cursor_finder()
    async.sleep(.25)
    assert(root._cursor_magnify() > 1, 'stopping an inactive instance cancelled the active one')
    b:stop_cursor_finder()

    -- Rings are ordinary input-passthrough widgets and move with the pointer.
    move(400, 300)
    local under = wibox {x = 250, y = 150, width = 400, height = 300,
        visible = true, bg = '#102030'}
    local rings = awful.accessibility {cursor_finder_duration = 3}
    rings:find_cursor()
    wait(function() return rings._private.ring_timer and rings._private.ring_timer.started end,
        'ring animation did not start')
    assert(mouse.current_wibox == under, 'locator intercepted pointer input')
    assert(rings._private.overlay.visible, 'ring overlay never became visible')
    assert(rings._private.ring_timer and rings._private.ring_timer.started, 'ring animation did not start')
    local function ring_extent()
        local shot = capture.new(s, 290, 190, 220, 220):shot()
        local furthest = 0
        for y = 0, 219 do
            for x = 0, 219 do
                local off = (y * 220 + x) * 4
                local b, g, r = shot:byte(off + 1, off + 3)
                if r > 45 and r > g * 1.3 and r > b * 1.3 then
                    furthest = math.max(furthest, math.sqrt((x - 110)^2 + (y - 110)^2))
                end
            end
        end
        return furthest
    end
    local outer = ring_extent()
    if outer <= 30 then io.stderr:write(awesome._clay_tree(s)) end
    assert(outer > 30, 'ring pixels were not drawn: ' .. outer)
    async.sleep(.8)
    local inner = ring_extent()
    assert(inner > 0 and inner < outer - 10, 'ring pixels did not shrink toward the pointer: ' .. outer .. ' -> ' .. inner)
    local old_x = rings._private.overlay.x
    mouse._fake_motion(30, 0)
    assert(rings._private.overlay.x == old_x + 30, 'ring overlay did not follow motion')
    wait(function() return not rings._private.overlay.visible end, 'ring overlay never finished')
    assert(root._cursor_magnify() == 1, 'rings changed cursor size')
    rings:find_cursor()
    rings:stop_cursor_finder()
    async.sleep(.1)
    assert(not rings._private.overlay.visible, 'cancelled rings restarted from a deferred callback')
    under.visible = false
    awful.accessibility.find_cursor()
    awful.accessibility.stop_cursor_finder()
    runner.done()
end)
