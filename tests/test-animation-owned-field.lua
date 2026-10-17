local runner = require('_runner')
local async = require('_async')
local wibox = require('wibox')
local awful = require('awful')
local ruled = require('ruled')
local utils = require('_utils')
local capture = require('_widget_capture')
local surface = require('gears.surface')
local gdebug = require('gears.debug')
local s = screen[1]

runner.run_async(function()
    local warnings = {}
    local print_warning = gdebug.print_warning
    gdebug.print_warning = function(message) warnings[#warnings + 1] = message end
    local widget = wibox.container.background(nil, '#202020')
    local owned = setmetatable({bg = 200}, {})
    owned.self = owned
    widget.animation = owned
    widget.animation = owned
    assert(widget.animation == owned, 'animation object lost its identity')
    assert(#warnings == 1, 'foreign animation did not warn once')
    assert(warnings[1]:find('wibox.clay: ' .. tostring(widget) .. ' animation', 1, true),
        'warning did not name the object and property')
    local bar = wibox {screen = s, x = 400, y = 200, width = 100, height = 80,
        visible = true, ontop = true, shadow = false, widget = widget}
    async.sleep(.15)
    widget.bg = '#e0e0e0'
    async.sleep(.15)
    local r = capture.read(surface(s.content), 420, 220)
    assert(r == 224, 'foreign animation object started a transition')
    assert(#warnings == 1, 'rendering a foreign animation emitted extra warnings')

    for _, value in ipairs{{self = {}}, {[1] = 200}, {bg = true}, setmetatable({bg = 200}, {})} do
        widget.animation = value
        assert(widget.animation == value, 'foreign table lost its identity')
    end
    assert(#warnings == 1, 'another foreign table warned again on the same object')
    local policy = {bg = 200}
    widget.animation = policy
    policy.bg = 0
    assert(widget.animation.bg == 200, 'policy assignment was not copied')
    local copy = widget.animation
    copy.bg = 0
    assert(widget.animation.bg == 200, 'policy read was not copied')
    widget.animation = {bg = 1}
    async.sleep(.15)
    widget.bg = '#202020'
    async.sleep(.2)
    r = capture.read(surface(s.content), 420, 220)
    assert(r > 32 and r < 224, 'numeric policy did not animate')
    widget.animation = owned
    widget.bg = '#e0e0e0'
    async.sleep(.15)
    r = capture.read(surface(s.content), 420, 220)
    assert(r == 224, 'foreign animation did not clear the property policy')
    bar.visible = false

    owned.visible = {duration = 200, enter = 'fade', exit = 'fade'}
    widget.animation = nil
    bar.animation = owned
    bar.animation = owned
    assert(bar.animation == owned, 'wibox lost the animation object')
    assert(#warnings == 2, 'wibox did not warn once')
    bar.visible = true
    async.sleep(.15)
    r = capture.read(surface(s.content), 420, 220)
    assert(r == 224, 'foreign wibox animation started an entrance')
    bar.visible = false

    local popup = awful.popup {screen = s, x = 400, y = 200, visible = false,
        ontop = true, shadow = false, animation = owned,
        widget = wibox.container.background(nil, '#e0e0e0')}
    popup.minimum_width, popup.minimum_height = 100, 80
    popup.animation = owned
    assert(popup.animation == owned, 'popup lost the animation object')
    assert(#warnings == 3, 'popup did not warn once')
    popup.visible = true
    async.sleep(.15)
    r = capture.read(surface(s.content), popup.x + 20, popup.y + 20)
    assert(r == 224, 'foreign popup animation started an entrance')
    popup.visible = false

    local binary = assert(utils.binary_or_skip('./build-test/test-transient-client'))
    local report = os.tmpname()
    local tag = s.selected_tag
    tag.layout, tag.gap = awful.layout.suit.tile, 0
    owned.layout = 200
    local rule = {rule = {class = 'ANIMATION_OWNED_FIELD'},
        properties = {animation = owned, floating = false, border_width = 0, shadow = false}}
    ruled.client.append_rule(rule)
    awful.spawn {binary, 'ANIMATION_OWNED_FIELD', report, '0', 'ff202020', '0'}
    assert(async.wait_for_condition(function() return utils.find_client_by_class('ANIMATION_OWNED_FIELD') end, 3, .02))
    local c = utils.find_client_by_class('ANIMATION_OWNED_FIELD')
    assert(c.animation == owned, 'client rule lost the animation object')
    c.animation = owned
    assert(#warnings == 4, 'client did not warn once')
    async.sleep(.15)
    local function width()
        local dump = awesome._clay_tree(s)
        for line in dump:gmatch('[^\n]+') do
            if line:find('CLIENT ANIMATION_OWNED_FIELD ', 1, true) then
                return tonumber(line:match('box %-?%d+,%-?%d+ (%d+)x%d+'))
            end
        end
        error('client missing from dump: ' .. dump)
    end
    tag.gap = 20
    async.sleep(.15)
    assert(width() == s.workarea.width - 40, 'foreign client policy animated layout')
    ruled.client.remove_rule(rule)
    rule.properties.animation = {layout = 1}
    ruled.client.append_rule(rule)
    ruled.client.apply(c)
    rule.properties.animation.layout = 200
    assert(c.animation.layout == 1, 'client rule policy was not copied')
    local client_copy = c.animation
    client_copy.layout = 200
    assert(c.animation.layout == 1, 'client getter exposed its policy')
    async.sleep(.15)
    tag.gap = 0
    async.sleep(.2)
    assert(width() > s.workarea.width - 40 and width() < s.workarea.width,
        'numeric client rule policy did not animate layout')
    c.animation = false
    c:kill()
    assert(async.wait_for_condition(function() return not c.valid end, 3, .02))
    ruled.client.remove_rule(rule)
    os.remove(report)
    gdebug.print_warning = print_warning
    runner.done()
end)
