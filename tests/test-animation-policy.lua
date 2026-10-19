-- timeout: 40
local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local wibox = require('wibox')
local animation = require('somewm.animation')
local capture = require('_widget_capture')
local surface = require('gears.surface')
local utils = require('_utils')
local s = screen[1]

local function pixel(expected)
    local r, g, b = capture.read(surface(s.content), 420, 220)
    assert(r == expected and g == expected and b == expected,
        'unexpected pixel: ' .. r .. ',' .. g .. ',' .. b)
end

local function snapshot(object, policy, edit, read)
    local changes = 0
    local function changed() changes = changes + 1 end
    object:connect_signal('property::animation', changed)
    object.animation = policy
    local original = read(object.animation)
    edit(policy)
    assert(read(object.animation) == original, 'assignment retained the caller table')
    local copy = object.animation
    edit(copy)
    assert(read(object.animation) == original, 'getter exposed the stored policy')
    assert(changes == 1, 'editing a copy emitted a policy signal')
    object.animation = copy
    assert(read(object.animation) == read(copy), 'reassignment did not apply edits')
    object.animation = false
    assert(object.animation == false, 'false was not preserved')
    object.animation = nil
    assert(object.animation == nil, 'nil did not remove the policy')
    assert(changes == 4, 'policy assignments did not emit signals')
    object:disconnect_signal('property::animation', changed)
end

runner.run_async(function()
    local wall = awful.wallpaper {screen = s, bg = '#202020'}
    mouse.coords{x = 1000, y = 600}
    local child = wibox.container.background(nil, '#e0e0e0')
    child.animation = {bg = 1}
    local bar = wibox {screen = s, x = 400, y = 200, width = 100, height = 80,
        visible = false, ontop = true, shadow = false, widget = child}
    snapshot(bar, {visible = {duration = 1, enter = 'fade'}},
        function(p) p.visible.duration = .5 end, function(p) return p.visible.duration end)
    snapshot(child, {bg = 1}, function(p) p.bg = .5 end, function(p) return p.bg end)
    child.animation = {bg = 1}

    for _, style in ipairs{'fade', 'grow', 'slide_left', 'slide_right', 'slide_up', 'slide_down'} do
        bar.animation = {visible = {duration = 1, enter = style, exit = style}}
        bar.visible = true
        async.sleep(.15)
        animation.enabled = false
        async.sleep(.12)
        pixel(224)
        assert(bar.x == 400 and bar.y == 200, 'disabled entrance did not settle')
        bar.visible = false
        async.sleep(.12)
        pixel(32)
        animation.enabled = true
        bar.visible = true
        async.sleep(1.1)
        bar.visible = false
        async.sleep(.15)
        animation.enabled = false
        async.sleep(.12)
        pixel(32)
        local dump = awesome._clay_tree(s)
        assert(not dump:find('FADE_START', 1, true), 'disabled exit retained its fade')
        animation.enabled = true
    end

    bar.animation = nil
    bar.visible = true
    async.sleep(.15)
    child.bg = '#202020'
    async.sleep(.2)
    local r = capture.read(surface(s.content), 420, 220)
    assert(r > 32 and r < 224, 'child did not start animating')
    bar.animation = false
    async.sleep(.12)
    pixel(32)
    child:animate {bg = '#e0e0e0', duration = 1}
    async.sleep(.12)
    pixel(224)
    bar.animation = nil
    child.bg = '#202020'
    async.sleep(.2)
    r = capture.read(surface(s.content), 420, 220)
    assert(r > 32 and r < 224, 'clearing host policy did not restore child animation')
    animation.enabled = false
    async.sleep(.12)
    pixel(32)
    animation.enabled = true
    child.bg = '#e0e0e0'
    async.sleep(.2)
    r = capture.read(surface(s.content), 420, 220)
    assert(r > 32 and r < 224, 'reenabling did not restore widget animation')
    mousegrabber.run(function() return true end, 'left_ptr')
    async.sleep(.12)
    pixel(224)
    mousegrabber.stop()
    bar.visible = false
    async.sleep(.12)
    child.animation = nil
    bar.animation = {visible = {duration = 1, enter = 'fade', exit = 'fade'}}
    bar.visible = true
    async.sleep(.2)
    bar.animation = false
    async.sleep(.12)
    pixel(224)
    bar.visible = false
    async.sleep(.12)
    bar.animation = {visible = {duration = 1, enter = 'fade', exit = 'fade'}}
    bar.visible = true
    async.sleep(.2)
    mousegrabber.run(function() return true end, 'left_ptr')
    async.sleep(.12)
    pixel(224)
    bar.visible = false
    async.sleep(.12)
    pixel(32)
    mousegrabber.stop()
    bar.visible = true
    async.sleep(1.1)
    bar.visible = false
    async.sleep(.2)
    bar.animation = false
    async.sleep(.12)
    pixel(32)

    local binary = assert(utils.binary_or_skip('./build-test/test-transient-client'))
    local report = os.tmpname()
    awful.spawn {binary, 'ANIMATION_POLICY', report, '0', 'ff202020', '0'}
    assert(async.wait_for_condition(function() return utils.find_client_by_class('ANIMATION_POLICY') end, 3, .02))
    local c = utils.find_client_by_class('ANIMATION_POLICY')
    snapshot(c, {layout = 1}, function(p) p.layout = .5 end, function(p) return p.layout end)
    c.floating, c.shadow, c.border_width = true, false, 0
    c:geometry{x = 50, y = 350, width = 200, height = 120}
    local header = wibox.container.background(nil, '#202020')
    header.animation = {bg = 1}
    awful.titlebar(c, {position = 'top', size = 24}):set_widget(header)
    async.sleep(.2)
    header.bg = '#e0e0e0'
    async.sleep(.2)
    local g = c:geometry()
    r = capture.read(surface(s.content), g.x + 10, g.y + 10)
    assert(r > 32 and r < 224, 'titlebar did not start animating')
    c.animation = false
    async.sleep(.12)
    r = capture.read(surface(s.content), g.x + 10, g.y + 10)
    assert(r == 224, 'client policy did not suppress titlebar animation')
    c.animation = nil
    header.bg = '#202020'
    async.sleep(.2)
    r = capture.read(surface(s.content), g.x + 10, g.y + 10)
    assert(r > 32 and r < 224, 'clearing client policy did not restore titlebar animation')
    c.animation = false
    c:kill()
    assert(async.wait_for_condition(function() return not c.valid end, 3, .02))
    os.remove(report)
    wall:detach()
    runner.done()
end)
