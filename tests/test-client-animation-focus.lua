-- timeout: 45
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

-- A hosted runner can stall for a large part of a short transition, so a
-- sample at a fixed delay may land before it starts or after it ends. Poll
-- instead, against a transition long enough that a stall cannot skip the
-- middle. pixels() waits on grim, so the loop runs here rather than inside
-- a wait_for_condition predicate.
local GLib = require('lgi').GLib
local function between(value) return value > 32 and value < 224 end
local function wait_all(list, test, message)
    local deadline, last = GLib.get_monotonic_time() + 8e6
    repeat
        local good = true
        for _, c in ipairs(list) do
            local values = {pcall(pixels, c)}
            if not table.remove(values, 1) then good, last = false, values[1] break end
            for _, value in ipairs(values) do
                if not test(value) then good, last = false, value break end
            end
            if not good then break end
        end
        if good then return end
        async.sleep(.02)
    until GLib.get_monotonic_time() > deadline
    error(message .. ': ' .. tostring(last))
end

runner.run_async(function()
    beautiful.animation_layout_duration = 0
    beautiful.animation_focus_duration = 3
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
    wait_all({clients[1]}, function(v) return v == 224 end, 'initial focused border')
    client.focus = clients[2]
    wait_all(clients, between, 'border did not interpolate')
    wait_all({clients[2]}, function(v) return v == 224 end, 'focused border did not settle')
    wait_all({clients[1]}, function(v) return v == 32 end, 'unfocused border did not settle')
    beautiful.animation_focus_duration = nil
    ruled.client.append_rule {
        rule = {class = 'FOCUS_ANIMATION_3'},
        properties = {animation = {focus = 3}, focus = false, floating = false, border_width = 8,
            border_color = beautiful.border_normal},
    }
    reports[3] = os.tmpname()
    awful.spawn{binary, 'FOCUS_ANIMATION_3', reports[3], '0', 'ff0000cc', '0'}
    clients[3] = assert(async.wait_for_client('FOCUS_ANIMATION_3', 2))
    assert(clients[3].animation.focus == 3, 'rule did not set focus duration')
    clients[3].shadow = false
    client.focus = clients[2]
    wait_all({clients[3]}, function(v) return v == 32 end, 'per-object unfocused border')
    client.focus = clients[3]
    wait_all({clients[3]}, between, 'per-object border faded from empty or snapped')
    wait_all({clients[3]}, function(v) return v == 224 end, 'per-object focused border did not settle')
    client.disconnect_signal('focus', focused)
    client.disconnect_signal('unfocus', unfocused)
    for i, c in ipairs(clients) do c:kill(); os.remove(reports[i]) end
    io.stderr:write('[PASS] focus border pixels interpolate and settle\n')
    runner.done()
end)
