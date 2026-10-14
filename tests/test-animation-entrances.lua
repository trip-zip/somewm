local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local beautiful = require('beautiful')
local ruled = require('ruled')
local wibox = require('wibox')
local utils = require('_utils')
local capture = require('_widget_capture')
local binary = assert(utils.binary_or_skip('./build-test/test-transient-client'))
local s = screen[1]

local function dump()
    local text = awesome._clay_tree(s)
    assert(not text:find('[tree!=scene]', 1, true), text)
    return text
end

local function box(role)
    for line in dump():gmatch('[^\n]+') do
        if line:match('^%s*' .. role .. ' ') then
            local x, y, w, h = line:match('box (%-?%d+),(%-?%d+) (%d+)x(%d+)')
            if x then return tonumber(x), tonumber(y), tonumber(w), tonumber(h) end
        end
    end
end

local function leaving_popup()
    for line in dump():gmatch('[^\n]+') do
        local x = line:match('box (%-?%d+),0 200x100')
        if x and tonumber(x) < 0 then return tonumber(x) end
    end
end

local function shrinking_client()
    for line in dump():gmatch('[^\n]+') do
        if line:match('^%s+%- w=') then
            local w, h = line:match('box %-?%d+,%-?%d+ (%d+)x(%d+)')
            if w and tonumber(w) > 0 and tonumber(w) < s.workarea.width
                and tonumber(h) > 0 and tonumber(h) < s.workarea.height then return true end
        end
    end
    return false
end

runner.run_async(function()
    local popup = awful.popup {
        screen = s, placement = awful.placement.top_left, visible = false, shadow = false,
        animation = {visible = {duration = 1, enter = 'slide_left', exit = 'slide_left'}},
        widget = capture.leaf_widget(200, 100, '#ff0000'),
    }
    assert(popup.animation.visible.enter == 'slide_left', 'popup did not forward animation')
    local policy_changes = 0
    popup:connect_signal('property::animation', function() policy_changes = policy_changes + 1 end)
    popup.visible = true
    async.sleep(.3)
    local x, _, w = box('POPUP')
    assert(x and x > -w and x < 0, 'popup did not slide in: ' .. dump())
    async.sleep(.9)
    x = box('POPUP')
    assert(x == 0, 'popup did not settle: ' .. dump())
    popup.visible = false
    async.sleep(.3)
    x = leaving_popup()
    assert(x and x > -200 and x < 0, 'popup did not slide out: ' .. dump())
    async.sleep(.9)
    assert(not leaving_popup() and not box('POPUP'), 'popup survived its exit: ' .. dump())

    for _, style in ipairs({'slide_right', 'slide_up', 'slide_down'}) do
        popup.animation = {visible = {duration = .2, enter = style, exit = style}}
        popup.visible = true
        async.sleep(.06)
        local px, py = box('POPUP')
        if style == 'slide_right' then
            assert(px > 0 and px < s.geometry.width, 'right slide ignored output edge: ' .. dump())
        elseif style == 'slide_down' then
            assert(py > 0 and py < s.geometry.height, 'down slide ignored output edge: ' .. dump())
        else
            assert(py > -100 and py < 0, 'up slide did not enter: ' .. dump())
        end
        async.sleep(.18)
        assert(box('POPUP') == 0 and select(2, box('POPUP')) == 0, 'slide did not settle')
        popup.visible = false
        async.sleep(.22)
    end
    assert(policy_changes == 3, 'popup did not forward policy changes')
    popup.animation = nil
    assert(popup.animation == nil and policy_changes == 4, 'popup did not clear its policy')
    local bar = wibox {screen = s, x = 0, y = 0, width = 120, height = 80,
        visible = false, shadow = false,
        animation = {visible = {duration = .2, enter = 'slide_left', exit = 'slide_left'}},
        widget = capture.leaf_widget(120, 80, '#00ff00')}
    assert(bar.animation and bar.animation.visible.duration == .2, 'wibox did not store animation')
    bar.visible = true
    async.sleep(.06)
    local bx = box('WIBOX')
    assert(bx and bx > -120 and bx < 0, 'wibox did not animate: ' .. dump())
    async.sleep(.18)
    assert(box('WIBOX') == 0, 'wibox did not settle')
    bar.visible = false
    bar = nil
    collectgarbage("collect")
    async.sleep(.22)

    beautiful.animation_appear_duration = 1
    beautiful.animation_disappear, beautiful.animation_disappear_duration = 'grow', .4
    beautiful.animation_tag_duration = .2
    ruled.client.append_rule {
        rule = {class = 'ENTRANCE_CLIENT'},
        properties = {animation = {appear = 'grow'}, border_width = 0, floating = false},
    }
    s.selected_tag.layout = awful.layout.suit.tile
    local report = os.tmpname()
    awful.spawn{binary, 'ENTRANCE_CLIENT', report, '0', 'ff0000cc', '0'}
    local c = assert(async.wait_for_client('ENTRANCE_CLIENT', 2))
    c.shadow = false
    async.sleep(.3)
    local _, _, width = box('CLIENT')
    assert(width and width > 0 and width < s.workarea.width, 'client did not grow on map: ' .. dump())
    async.sleep(.9)
    assert(select(3, box('CLIENT')) == s.workarea.width, 'client entrance did not settle: ' .. dump())
    local original = s.selected_tag
    local other = awful.tag.add('entrance-empty', {screen = s, layout = awful.layout.suit.tile})
    other:view_only()
    async.sleep(.1)
    assert(not box('CLIENT'), 'client remained declared after tag switch: ' .. dump())
    assert(shrinking_client(), 'client did not shrink on tag exit: ' .. dump())
    async.sleep(.2)
    original:view_only()
    async.sleep(.1)
    width = select(3, box('CLIENT'))
    assert(width and width > 0 and width < s.workarea.width, 'client did not grow on tag entry: ' .. dump())
    async.sleep(.2)
    assert(select(3, box('CLIENT')) == s.workarea.width, 'tag entrance did not settle')
    other:delete()
    c:kill()
    assert(async.wait_for_condition(function() return not c.valid end, 2, .01), 'client did not unmanage')
    c = nil
    collectgarbage("collect")
    async.sleep(.1)
    assert(shrinking_client(), 'client did not shrink on unmanage: ' .. dump())
    async.sleep(.4)
    assert(not shrinking_client(), 'client survived its departure')
    os.remove(report)
    io.stderr:write('[PASS] popup slides, client appearance and tag entrances\n')
    runner.done()
end)
