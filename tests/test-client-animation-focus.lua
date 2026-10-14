local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local beautiful = require('beautiful')
local ruled = require('ruled')
local utils = require('_utils')
local capture = require('_widget_capture')
local surface = require('gears.surface')
local binary = assert(utils.binary_or_skip('./build-test/test-transient-client'))
local s = screen[1]

local function dump()
    local text = awesome._clay_tree(s)
    assert(not text:find('[tree!=scene]', 1, true), text)
    return text
end

local function frame(c)
    for text in dump():gmatch('[^\n]+') do
        if text:find('CLIENT ' .. c.class .. ' ', 1, true) then
            local x, y, w, h = text:match('box (%-?%d+),(%-?%d+) (%d+)x(%d+)')
            return tonumber(x), tonumber(y), tonumber(w), tonumber(h)
        end
    end
    error('missing frame for ' .. c.class)
end

local function pixels(c)
    local x, y, _, h = frame(c)
    local red, green, blue = capture.read(surface(s.content), x + 2, y + math.floor(h / 2))
    if utils.is_headless() then
        local path, done, data, failure = os.tmpname(), false
        awful.spawn.easy_async({'grim', '-t', 'ppm', path}, function(_, stderr, _, code)
            if code == 0 then
                local file = assert(io.open(path, 'rb'))
                data = file:read('*a')
                file:close()
            else
                failure = 'grim failed: ' .. tostring(stderr)
            end
            os.remove(path)
            done = true
        end)
        assert(async.wait_for_condition(function() return done end, 2, .01), 'grim timed out')
        assert(not failure, failure)
        local width, header = data:match('^P6%s+(%d+)%s+%d+%s+255%s()')
        assert(width, 'grim did not produce P6')
        local offset = header + ((y + math.floor(h / 2)) * tonumber(width) + x + 2) * 3
        local r, g, b = data:byte(offset, offset + 2)
        return red, green, blue, r, g, b
    end
    return red, green, blue
end

runner.run_async(function()
    beautiful.animation_layout_duration = 0
    beautiful.animation_focus_duration = 1
    beautiful.border_normal, beautiful.border_focus = '#202020', '#e0e0e0'
    local function focused(c) c.border_color = beautiful.border_focus end
    local function unfocused(c) c.border_color = beautiful.border_normal end
    client.connect_signal('focus', focused)
    client.connect_signal('unfocus', unfocused)
    s.selected_tag.layout = awful.layout.suit.tile
    local clients, reports = {}, {}
    for i = 1, 2 do
        local name, report = 'FOCUS_ANIMATION_' .. i, os.tmpname()
        reports[i] = report
        awful.spawn{binary, name, report, '0', 'ff0000cc', '0'}
        clients[i] = assert(async.wait_for_client(name, 2))
        clients[i].floating, clients[i].shadow = false, false
        clients[i].border_width = 8
        clients[i].border_color = beautiful.border_normal
    end
    mouse.coords{x = 1270, y = 710}
    client.focus = clients[1]
    focused(clients[1])
    async.sleep(1.2)
    for _, value in ipairs({pixels(clients[1])}) do assert(value == 224, 'initial focused border: ' .. value) end
    client.focus = clients[2]
    async.sleep(.3)
    for _, c in ipairs(clients) do
        for _, value in ipairs({pixels(c)}) do
            assert(value > 32 and value < 224, 'border did not interpolate: ' .. value)
        end
    end
    async.sleep(.9)
    for _, value in ipairs({pixels(clients[2])}) do assert(value == 224, 'focused border did not settle: ' .. value) end
    for _, value in ipairs({pixels(clients[1])}) do assert(value == 32, 'unfocused border did not settle: ' .. value) end
    beautiful.animation_focus_duration = nil
    ruled.client.append_rule {
        rule = {class = 'FOCUS_ANIMATION_3'},
        properties = {animate = {focus = 1}, focus = false, floating = false, border_width = 8,
            border_color = beautiful.border_normal},
    }
    reports[3] = os.tmpname()
    awful.spawn{binary, 'FOCUS_ANIMATION_3', reports[3], '0', 'ff0000cc', '0'}
    clients[3] = assert(async.wait_for_client('FOCUS_ANIMATION_3', 2))
    assert(clients[3].animate.focus == 1, 'rule did not set focus duration')
    clients[3].shadow = false
    client.focus = clients[2]
    async.sleep(1.2)
    for _, value in ipairs({pixels(clients[3])}) do
        assert(value == 32, 'per-object unfocused border: ' .. value)
    end
    client.focus = clients[3]
    async.sleep(.3)
    for _, value in ipairs({pixels(clients[3])}) do
        assert(value > 32 and value < 224, 'per-object border faded from empty or snapped: ' .. value)
    end
    async.sleep(.9)
    for _, value in ipairs({pixels(clients[3])}) do
        assert(value == 224, 'per-object focused border did not settle: ' .. value)
    end
    client.disconnect_signal('focus', focused)
    client.disconnect_signal('unfocus', unfocused)
    for i, c in ipairs(clients) do c:kill(); os.remove(reports[i]) end
    io.stderr:write('[PASS] focus border pixels interpolate and settle\n')
    runner.done()
end)
