-- timeout: 20
local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local beautiful = require('beautiful')
local ruled = require('ruled')
local wibox = require('wibox')
local capture = require('_widget_capture')
local surface = require('gears.surface')
local utils = require('_utils')
local binary = assert(utils.binary_or_skip('./build-test/test-transient-client'))
local s = screen[1]

local function dump()
    local text = awesome._clay_tree(s)
    assert(not text:find('[tree!=scene]', 1, true), text)
    return text
end

local function alpha(role, x, y)
    for line in dump():gmatch('[^\n]+') do
        local bx, by, bw, bh = line:match('box (%-?%d+),(%-?%d+) (%d+)x(%d+)')
        local inside = not x or bx and x >= tonumber(bx) and x < tonumber(bx) + tonumber(bw)
            and y >= tonumber(by) and y < tonumber(by) + tonumber(bh)
        if inside and line:match('^%s*' .. role .. ' ') then
            return tonumber(line:match('fade_alpha ([%d.]+)')) or 0
        end
    end
    error('missing ' .. role .. ': ' .. dump())
end

local function pixels(x, y)
    local r, g, b = capture.read(surface(s.content), x, y)
    local values = {r, g, b}
    if utils.is_headless() then
        local path, done, data, failure = os.tmpname(), false
        awful.spawn.easy_async({'grim', '-t', 'ppm', path}, function(_, stderr, _, code)
            if code == 0 then
                local file = assert(io.open(path, 'rb'))
                data = file:read('*a')
                file:close()
            else failure = stderr end
            os.remove(path)
            done = true
        end)
        assert(async.wait_for_condition(function() return done end, 2, .01), 'grim timed out')
        assert(not failure, failure)
        local width, header = data:match('^P6%s+(%d+)%s+%d+%s+255%s()')
        assert(width, 'grim did not produce P6')
        local offset = header + (y * tonumber(width) + x) * 3
        for channel = 0, 2 do values[#values + 1] = data:byte(offset + channel) end
    end
    return values
end

local function intermediate(role, x, y, opacity)
    local before = alpha(role, x, y)
    assert(before > 0 and before < 1, 'fade alpha did not interpolate: ' .. before)
    local values = pixels(x, y)
    local after = alpha(role, x, y)
    local low = 32 + 192 * opacity * (1 - math.max(before, after))
    local high = 32 + 192 * opacity * (1 - math.min(before, after))
    for _, value in ipairs(values) do
        assert(value > 32 and value < 32 + 192 * opacity, 'pixel did not fade: ' .. value .. '\n' .. dump())
        assert(value >= low - 3 and value <= high + 3,
            'pixel disagrees with dump alpha: ' .. value .. ' expected ' .. low .. '..' .. high .. '\n' .. dump())
    end
end

local function exact(x, y, expected)
    for _, value in ipairs(pixels(x, y)) do assert(value == expected, 'pixel did not settle: ' .. value) end
end

runner.run_async(function()
    local wall = awful.wallpaper {screen = s, bg = '#202020'}
    mouse.coords{x = 1200, y = 650}
    local popup = awful.popup {
        screen = s, placement = awful.placement.top_left, visible = false, shadow = false, bg = "#00000000",
        animation = {visible = {duration = 1, enter = 'fade', exit = 'fade'}},
        widget = capture.leaf_widget(200, 100, '#e0e0e0'),
    }
    async.sleep(.1)
    exact(20, 20, 32)
    popup.visible = true
    async.sleep(.3)
    intermediate('POPUP', 20, 20, 1)
    async.sleep(.9)
    exact(20, 20, 224)
    assert(alpha('POPUP') == 0, 'entrance alpha did not settle')
    popup.visible = false
    async.sleep(.3)
    intermediate('%-', 20, 20, 1)
    async.sleep(.9)
    exact(20, 20, 32)
    assert(not dump():match('POPUP screen'), 'popup survived its fade exit')

    popup.animation = {visible = {duration = .25, enter = 'fade', exit = 'fade'}}
    popup.opacity = .5
    popup.visible = true
    async.sleep(.08)
    intermediate('POPUP', 20, 20, .5)
    async.sleep(.22)
    exact(20, 20, 128)
    popup.visible = false
    async.sleep(.3)

    local bar = wibox {screen = s, x = 500, y = 0, width = 120, height = 60,
        visible = false, shadow = false, bg = '#00000000',
        animation = {visible = {duration = .25, enter = 'fade', exit = 'fade'}},
        widget = capture.leaf_widget(120, 60, '#e0e0e0')}
    bar.visible = true
    async.sleep(.08)
    intermediate('WIBOX', 520, 20, 1)
    async.sleep(.22)
    exact(520, 20, 224)
    bar.visible = false
    async.sleep(.08)
    intermediate('%-', 520, 20, 1)
    async.sleep(.22)
    exact(520, 20, 32)

    beautiful.shadow_enabled, beautiful.shadow_drawin_enabled = true, true
    beautiful.shadow_radius, beautiful.shadow_spread = 12, 0
    beautiful.shadow_offset_x, beautiful.shadow_offset_y = 0, 0
    beautiful.shadow_opacity, beautiful.shadow_color = .75, '#000000'
    awesome.shadow_reload()
    bar.shadow = true
    bar.animation = {visible = {duration = .25, enter = 'fade'}}
    bar.visible = true
    async.sleep(.08)
    local shadow_alpha = alpha('WIBOX', 520, 20)
    assert(shadow_alpha > 0 and shadow_alpha < 1, 'shadow alpha did not interpolate: ' .. shadow_alpha)
    local shadow_mid = pixels(621, 30)
    local shadow_after = alpha('WIBOX', 520, 20)
    async.sleep(.22)
    local shadow_final = pixels(621, 30)
    for i, value in ipairs(shadow_mid) do
        -- The CPU capture is immediate; grim can capture a later animation frame.
        if i <= 3 then
            assert(shadow_final[i] < value and value < 32, 'shadow did not fade: mid=' .. value .. ' final=' .. shadow_final[i] .. ' alpha=' .. shadow_alpha .. '\n' .. dump())
        end
        local low = 32 + (shadow_final[i] - 32) * (1 - math.min(shadow_alpha, shadow_after))
        local high = 32 + (shadow_final[i] - 32) * (1 - math.max(shadow_alpha, shadow_after))
        assert(value >= low - 3 and value <= high + 3,
            'shadow pixel disagrees with fade alpha: ' .. value .. ' expected ' .. low .. '..' .. high .. '\n' .. dump())
    end
    bar.visible = false
    async.sleep(.1)

    beautiful.animation_appear_duration = 1
    ruled.client.append_rule {
        rule = {class = 'FADE_CLIENT'},
        properties = {animation = {appear = 'fade'}, floating = true, border_width = 0,
            shadow = false, x = 300, y = 100, width = 200, height = 100},
    }
    local report = os.tmpname()
    awful.spawn{binary, 'FADE_CLIENT', report, '0', 'ffe0e0e0', '0'}
    local c = assert(async.wait_for_client('FADE_CLIENT', 2))
    async.sleep(.3)
    local geometry = c:geometry()
    intermediate('CLIENT', geometry.x + 20, geometry.y + 20, 1)
    async.sleep(.9)
    exact(geometry.x + 20, geometry.y + 20, 224)
    assert(alpha('CLIENT') == 0, 'client entrance alpha did not settle')
    c:kill()
    os.remove(report)
    async.sleep(.05)
    beautiful.animation_appear_duration = nil
    beautiful.animation_tag_duration = 1
    beautiful.animation_disappear_duration = 1
    s.selected_tag.layout = awful.layout.suit.tile
    local home = s.selected_tag
    home.gap = 7
    local away = awful.tag.add('fade-away', {screen = s, layout = awful.layout.suit.tile})
    local function chrome_client(class, animation)
        ruled.client.append_rule {
            rule = {class = class},
            properties = {animation = animation, floating = false, border_width = 0, shadow = false},
        }
        local path = os.tmpname()
        awful.spawn{binary, class, path, '0', 'ffe0e0e0', '0', '0', '0', '16'}
        local item = assert(async.wait_for_client(class, 2))
        assert(async.wait_for_condition(function() return awesome._clay_tree(s):match('CHROME ') end, 1, .01),
            'client frame did not hold chrome: ' .. dump())
        io.stderr:write('[PASS] chrome client before exit\n', dump(), '\n')
        local box = item:geometry()
        exact(box.x + 20, box.y + 20, 224)
        return item, path, box.x + 20, box.y + 20
    end
    local tagged, tag_report, tx, ty = chrome_client('FADE_TAG', {tag = 'fade'})
    away:view_only()
    async.sleep(.3)
    local exiting = alpha('%-')
    assert(exiting > 0 and exiting < 1, 'tag exit alpha did not interpolate: ' .. exiting)
    async.sleep(.9)
    assert(not dump():match('^%s*%- ') and not dump():match('\n%s*%- '), 'tag exit remained in dump')
    home:view_only()
    async.sleep(.3)
    intermediate('CLIENT', tx, ty, 1)
    async.sleep(.9)
    exact(tx, ty, 224)
    tagged.floating = true
    tagged:geometry{width = 1248, height = 688}
    assert(async.wait_for_condition(function() return not awesome._clay_tree(s):match('CHROME ') end, 2, .01),
        'client did not become plain: ' .. dump())
    async.sleep(.3)
    local plain = dump()
    assert(not plain:match('CHROME '), 'client did not become plain: ' .. plain)
    assert(not plain:match('\n%s*%- w='), 'ghost exit remained: ' .. plain)
    local _, clients = plain:gsub('\n%s*CLIENT ', '')
    assert(clients == 1, 'expected one client, got ' .. clients .. ': ' .. plain)
    tagged:kill()
    os.remove(tag_report)
    async.sleep(.05)
    local departing, exit_report = chrome_client('FADE_DISAPPEAR', {disappear = 'fade'})
    departing:kill()
    async.sleep(.3)
    exiting = alpha('%-')
    assert(exiting > 0 and exiting < 1, 'disappear alpha did not interpolate: ' .. exiting)
    async.sleep(.9)
    assert(not dump():match('^%s*%- ') and not dump():match('\n%s*%- '), 'client exit remained in dump')
    assert(#client.get() == 0, 'client survived unmanage')
    os.remove(exit_report)
    away:delete()
    wall:remove_screen(s)
    runner.done()
end)
