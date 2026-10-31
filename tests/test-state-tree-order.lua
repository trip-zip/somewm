-- Client sibling order is bottom first. Layer changes preserve that order.
local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local wibox = require('wibox')
local capture = require('_widget_capture')
local surface = require('gears.surface')
local utils = require('_utils')
local binary = utils.binary_or_skip('./build-test/test-transient-client')
if not binary then return end

runner.run_async(function()
    local s = screen[1]
    s.selected_tag.layout = awful.layout.suit.floating
    local clients = {}
    local function spawn(name)
        local pid = awful.spawn {binary, name}
        local c = assert(async.wait_for_client(name, 3))
        c.floating, c.border_width, c.shadow = true, 0, false
        c.animation = false
        c:geometry {x = 100, y = 100, width = 200, height = 200}
        clients[#clients + 1] = c
        return c, pid
    end

    local a, pid = spawn('tree_order_a')
    local b = spawn('tree_order_b')
    local c = spawn('tree_order_c')
    local bar = awful.wibar {screen = s, position = 'top', height = 24,
        bg = '#ff0000'}
    mouse.coords {x = 900, y = 600}
    async.sleep(.2)
    local function pixel()
        return capture.read(surface(s.content), 40, 12)
    end
    local r, g, blue = pixel()
    assert(r > 240 and g < 5 and blue < 5, 'wibar pixel is red before fullscreen')
    a.fullscreen = true
    client.focus = a
    async.sleep(.2)
    client.focus = b
    async.sleep(.2)
    assert(a.fullscreen and client.focus == b and a.screen == b.screen)
    -- Guard the existing fullscreen z band, which is independent of focus.
    -- The backing beneath an unfocused fullscreen client is declared separately.
    r, g, blue = pixel()
    assert(math.abs(r - 64) < 3 and math.abs(g - 64) < 3 and math.abs(blue - 64) < 3,
        string.format('unfocused fullscreen covers wibar pixel: got %d,%d,%d', r, g, blue))
    io.stderr:write('[PASS] unfocused fullscreen covers same-screen wibar pixel\n')
    a.fullscreen = false
    bar.visible = false

    local function position(list, object)
        for i, item in ipairs(list) do
            if item == object then return i end
        end
        error('object is missing from order')
    end
    local function above(top, bottom)
        local draw = awesome._test_declare_order(s)
        local stacked = client.get(s, true)
        return position(draw, top) > position(draw, bottom)
            and position(stacked, top) < position(stacked, bottom)
    end
    local function settles(check, message)
        assert(async.wait_for_condition(function()
            local ok, result = pcall(check)
            return ok and result
        end, 3, .02), message)
        io.stderr:write('[PASS] ' .. message .. '\n')
    end
    local function same_order(before, after)
        if #before ~= #after then return false end
        for i, object in ipairs(before) do
            if object ~= after[i] then return false end
        end
        return true
    end

    local box = wibox {screen = s, x = 120, y = 120, width = 100, height = 40,
        visible = true, bg = '#00ff00', widget = wibox.widget.textbox('wibox')}
    b.above = true
    settles(function()
        local draw = awesome._test_declare_order(s)
        return position(draw, a) < position(draw, box.drawin)
            and position(draw, box.drawin) < position(draw, b)
    end, 'plain wibox draws above a normal floating client and below an above client')
    b.above, b.ontop, box.ontop = false, true, true
    settles(function()
        local draw = awesome._test_declare_order(s)
        return position(draw, b) < position(draw, box.drawin)
    end, 'ontop wibox draws above an ontop client')
    local notification = wibox {screen = s, x = 140, y = 140, width = 100, height = 40,
        visible = true, ontop = true, type = 'notification', bg = '#0000ff',
        widget = wibox.widget.textbox('notification')}
    settles(function()
        local draw = awesome._test_declare_order(s)
        return position(draw, box.drawin) < position(draw, notification.drawin)
    end, 'notification draws above an ontop wibox')
    bar.ontop, bar.visible = true, true
    settles(function()
        local draw = awesome._test_declare_order(s)
        return position(draw, b) < position(draw, bar.drawin)
            and position(draw, bar.drawin) < position(draw, box.drawin)
    end, 'ontop wibar draws above an ontop client and below an ontop wibox')
    box.visible, notification.visible, bar.visible, b.ontop = false, false, false, false

    local managed = client.get(s)
    a:raise()
    settles(function()
        return above(a, b) and above(a, c) and client.get(s, true)[1] == a
    end, 'raise A puts A last in commands and first in stacked clients')
    assert(same_order(managed, client.get(s)), 'raise preserves manage order')
    a:lower()
    b:lower()
    settles(function() return above(a, b) and above(c, a) end,
        'lower A then lower B leaves B below A')

    local siblings = client.get(s, true)
    b.above = true
    settles(function() return position(awesome._test_declare_order(s), b)
            > position(awesome._test_declare_order(s), a) and b._scene_layer == 'top' end, 'above changes the layer without moving siblings')
    assert(same_order(siblings, client.get(s, true)), 'above preserves sibling order')
    b.above = nil
    settles(function() return above(a, b) end, 'clearing above restores draw order')
    assert(same_order(siblings, client.get(s, true)), 'clearing above preserves siblings')

    b.ontop, c.ontop = true, true
    a:raise()
    settles(function() return above(c, b) end,
        'two ontop clients keep their relative order when a third is raised')
    b.ontop, c.ontop = false, false

    awesome.kill(pid, 10)
    local child
    assert(async.wait_for_condition(function()
        for _, object in ipairs(client.get(s)) do
            if object.transient_for == a then child = object; return true end
        end
    end, 3), 'transient appeared')
    child.floating, child.animation = true, false
    a:raise()
    settles(function() return above(child, a) and above(a, b) and above(a, c) end,
        'transient follows its raised owner')
    child:lower()
    settles(function() return above(child, a) and above(b, child) and above(c, child) end,
        'lowering a transient puts its owner below it')
    a:lower()
    settles(function() return above(child, a) end, 'transient stays above its lowered owner')

    child:kill()
    assert(async.wait_for_condition(function() return not child.valid end, 3))
    for _, modal in ipairs {false, true} do
        local name = modal and 'tree_modal_owner' or 'tree_late_owner'
        local late_pid = awful.spawn {binary, '--late-parent', name}
        local late = assert(async.wait_for_client('transient_test_child', 3))
        late.floating, late.animation = true, false
        assert(not late.transient_for, 'child is managed without an owner')
        if modal then late.modal = true end
        awesome.kill(late_pid, 10)
        local owner = assert(async.wait_for_client(name, 3))
        owner.floating, owner.animation = true, false
        late:lower()
        owner:raise()
        settles(function() return above(owner, late) end, 'owner starts above the earlier child')
        awesome.kill(late_pid, 12)
        settles(function()
            if late.transient_for ~= owner then return false end
            local stacked = client.get(s, true)
            return above(late, owner) and position(stacked, owner) == position(stacked, late) + 1
        end, modal and 'modal before transient_for links immediately above owner'
            or 'earlier transient links immediately above owner')
        awesome.kill(late_pid, 15)
        assert(async.wait_for_condition(function() return not late.valid and not owner.valid end, 3))
    end

    for _, object in ipairs(clients) do
        if object.valid then object:kill() end
    end
    assert(async.wait_for_condition(function() return #client.get() == 0 end, 3))
    runner.done()
end)
