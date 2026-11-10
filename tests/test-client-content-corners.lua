-- Corner tables replace all four values and remain independent of shape.
local runner = require('_runner')
local awful = require('awful')
local ruled = require('ruled')
local utils = require('_utils')
local shot = require('_shape_mask_capture')
local color = require('gears.color')
local keys = {'top_left', 'top_right', 'bottom_right', 'bottom_left'}
local c, report, rule_client, rule_report
local signals, enters, leaves = 0, 0, 0
local steps = {}
local wallpaper, ink, frame = '#123456', '#204060', '#ff00ff'

local function expect(values)
    local got = c.content_radius
    assert(type(got) == 'table', 'table form was lost')
    local count = 0
    for _ in pairs(got) do count = count + 1 end
    assert(count == 4, 'getter must return all four named corners')
    for i, key in ipairs(keys) do assert(got[key] == values[i], key .. ' differs') end
end

local function declaration(radii)
    local dump = awesome._clay_tree(screen[1])
    local line = assert(dump:match('\n( *SURFACE corner_table [^\n]*)'))
    if radii then assert(line:find(' radii ' .. radii, 1, true), line)
    else assert(not line:find(' radii ', 1, true), line) end
end

steps[#steps + 1] = function()
    screen[1].scale = 1
    root.wallpaper(color(wallpaper))
    screen[1].selected_tag.layout = awful.layout.suit.floating
    mouse.coords{x = 0, y = 0}
    report = os.tmpname()
    awful.spawn{'./build-test/test-transient-client', 'corner_table', report, '0', 'ff204060'}
    return true
end
steps[#steps + 1] = function(n)
    c = utils.find_client_by_class('corner_table')
    if not c then assert(n < 30, 'client did not map'); return end
    c.floating, c.shadow, c.animation = true, false, false
    c.border_width, c.border_color = 0, frame
    c.shape = nil
    c:geometry{x = 40, y = 40, width = 300, height = 220}
    c:connect_signal('property::content_radius', function() signals = signals + 1 end)
    c.content_radius = 18
    assert(c.content_radius == 18 and signals == 1)
    local input = {top_left = 18, top_right = 18}
    c.content_radius = input
    expect{18, 18, 0, 0}; assert(signals == 2)
    input.bottom_left = 30
    local readback = c.content_radius
    readback.top_left = 90
    expect{18, 18, 0, 0}; assert(signals == 2, 'table mutation emitted a signal')
    c.content_radius = {bottom_left = 0, top_right = 18, top_left = 18, bottom_right = 0}
    assert(signals == 2, 'equivalent table emitted a signal')
    for _, bad in ipairs{-1, 0/0, math.huge, 1e100, '18', false,
            {top_left = -1}, {top_left = 0/0}, {top_left = math.huge},
            {top_left = 1e100}, {top_left = '18'}, {top_left = false},
            {top_left = {}}, {top_left = 12, typo = 8}, {18, 18, 0, 0},
            {[false] = 18}, {['top_left\0extra'] = 18}} do
        assert(not pcall(function() c.content_radius = bad end), 'invalid corner value accepted')
        expect{18, 18, 0, 0}
        assert(signals == 2, 'invalid assignment changed the property')
    end
    c.content_radius = {bottom_right = 12}
    expect{0, 0, 12, 0}; assert(signals == 3, 'partial assignment must replace all corners')
    c.content_radius = {top_left = 18, top_right = 18}
    return true
end
shot.check_steps(steps, function()
    declaration('18,18,0,0')
    return {{40, 40, frame}, {339, 40, frame}, {40, 259, ink}, {339, 259, ink},
        {58, 58, ink}, {321, 58, ink}}
end)
steps[#steps + 1] = function()
    c:connect_signal('mouse::enter', function() enters = enters + 1 end)
    c:connect_signal('mouse::leave', function() leaves = leaves + 1 end)
    mouse.coords{x = 40, y = 40}; mouse._fake_motion(0, 0)
    return true
end
steps[#steps + 1] = shot.wait(function() assert(enters == 1 and leaves == 0, 'rounded cut is client chrome') end)
steps[#steps + 1] = function()
    mouse.coords{x = 40, y = 259}; mouse._fake_motion(0, 0)
    return true
end
steps[#steps + 1] = shot.wait(function() assert(enters == 1 and leaves == 0, 'square corner left client') end)
steps[#steps + 1] = function()
    mouse.coords{x = 0, y = 0}; mouse._fake_motion(0, 0)
    c.shape = 24
    c.content_radius = {}
    expect{0, 0, 0, 0}
    local before = signals
    c.content_radius = {top_left = 0}
    assert(signals == before, 'equivalent square table emitted a signal')
    return true
end
shot.check_steps(steps, function()
    declaration(nil)
    assert(leaves == 1, 'outside client did not leave')
    return {{40, 40, wallpaper}, {339, 40, wallpaper}, {40, 259, wallpaper}, {339, 259, wallpaper}}
end)
for _, reset in ipairs{function() c.content_radius = nil end, function() c.content_radius = 0 end} do
    steps[#steps + 1] = function()
        c.content_radius = {}
        local before = signals
        reset()
        assert(c.content_radius == nil and signals == before + 1, 'reset must remove explicit square override')
        c.content_radius = 0
        assert(signals == before + 1, 'nil and numeric zero must be equivalent')
        return true
    end
    shot.check_steps(steps, function()
        declaration('24,24,24,24')
        return {{40, 40, wallpaper}, {339, 40, wallpaper}, {40, 259, wallpaper}, {339, 259, wallpaper},
            {64, 64, ink}}
    end)
end
steps[#steps + 1] = function()
    c.content_radius = {top_left = 18, top_right = 18, bottom_right = 18, bottom_left = 18}
    local before = signals
    c.content_radius = 18
    assert(c.content_radius == 18 and signals == before + 1, 'scalar form must replace table form')
    ruled.client.append_rule{id = 'corner-rule', rule = {class = 'corner_rule'},
        properties = {content_radius = {top_right = 12, bottom_left = 24}, titlebars_enabled = false}}
    rule_report = os.tmpname()
    awful.spawn{'./build-test/test-transient-client', 'corner_rule', rule_report, '0', 'ff204060'}
    return true
end
steps[#steps + 1] = function(n)
    rule_client = utils.find_client_by_class('corner_rule')
    if not rule_client then assert(n < 30, 'rule client did not map'); return end
    local value = rule_client.content_radius
    assert(value.top_left == 0 and value.top_right == 12 and value.bottom_right == 0 and value.bottom_left == 24,
        'rule did not preserve the corner table')
    ruled.client.remove_rule('corner-rule')
    rule_client:kill(); c:kill(); os.remove(report); os.remove(rule_report)
    io.stderr:write('[PASS] corner table replacement, copy semantics, errors, signals, rules, square override and pointer\n')
    return true
end
runner.run_steps(steps, {kill_clients = false})
