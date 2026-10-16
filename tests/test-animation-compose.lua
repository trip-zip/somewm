-- timeout: 60
local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local beautiful = require('beautiful')
local ruled = require('ruled')
local wibox = require('wibox')
local animation = require('somewm.animation')
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

local function frame()
    return assert(tonumber(dump():match('frames (%d+)')))
end

local function next_frame()
    local previous = frame()
    assert(async.wait_for_condition(function() return frame() > previous end, 1, .001), 'no rendered frame')
end

local function box(role, class)
    for line in dump():gmatch('[^\n]+') do
        if line:match('^%s*' .. role .. ' ') and (not class or line:find(class, 1, true)) then
            local x, y, w, h = line:match('box (%-?%d+),(%-?%d+) (%d+)x(%d+)')
            if x then
                return {x = tonumber(x), y = tonumber(y), w = tonumber(w), h = tonumber(h),
                    alpha = tonumber(line:match('fade_alpha ([%d.]+)')) or 0}
            end
        end
    end
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

local function exact(x, y, expected)
    for _, value in ipairs(pixels(x, y)) do
        assert(value == expected, 'pixel ' .. value .. ' expected ' .. expected .. '\n' .. dump())
    end
end

local function between(x, y)
    for _, value in ipairs(pixels(x, y)) do
        assert(value > 32 and value < 224, 'pixel did not blend: ' .. value .. '\n' .. dump())
    end
end

local function close(a, b)
    for _, key in ipairs{'x', 'y', 'w', 'h'} do
        assert(math.abs(a[key] - b[key]) <= 1, 'interruption jumped on ' .. key .. '\n' .. dump())
    end
    assert(math.abs(a.alpha - b.alpha) <= 1 / 255, 'interruption jumped in alpha')
end

local function read(path)
    local file = assert(io.open(path, 'r'))
    local text = file:read('*a')
    file:close()
    return text
end

local function warnings()
    local result = {}
    for line in read(assert(os.getenv('SOMEWM_TEST_LOG'))):gmatch('[^\n]+') do
        if line:find('conflict;', 1, true) then result[#result + 1] = line end
    end
    return result
end

runner.run_async(function()
    local wall = awful.wallpaper {screen = s, bg = '#202020'}
    mouse.coords{x = 1200, y = 650}
    local popup = awful.popup {
        screen = s, placement = awful.placement.top_left, visible = false, shadow = false, bg = '#00000000',
        animation = {visible = {duration = 1, enter = {'fade', 'slide_left'}, exit = {'slide_left', 'fade'}}},
        widget = capture.leaf_widget(200, 100, '#e0e0e0'),
    }
    local policy = popup.animation
    policy.visible.enter[1] = 'grow'
    assert(popup.animation.visible.enter[1] == 'fade', 'getter exposed the stored effect list')
    async.sleep(.1)
    exact(20, 20, 32)
    popup.visible = true
    async.sleep(.3)
    local mid = assert(box('POPUP'))
    assert(mid.x > -mid.w and mid.x < 0 and mid.alpha > 0 and mid.alpha < 1, dump())
    between(20, 20)
    async.sleep(.9)
    local settled = assert(box('POPUP'))
    assert(settled.x == 0 and settled.w == 200 and settled.alpha == 0, dump())
    exact(20, 20, 224)
    popup.visible = false
    async.sleep(.3)
    mid = assert(box('%-'))
    assert(mid.x > -mid.w and mid.x < 0 and mid.alpha > 0 and mid.alpha < 1, dump())
    between(20, 20)
    async.sleep(.9)
    assert(not box('POPUP') and not box('%-'), 'popup exit survived')
    exact(20, 20, 32)

    popup.visible = true
    async.sleep(.3)
    local before = assert(box('POPUP'))
    popup.visible = false
    assert(async.wait_for_condition(function() return box('%-') end, 1, .001))
    local previous = assert(box('%-'))
    close(before, previous)
    local samples = 0
    while box('%-') do
        next_frame()
        local current = box('%-')
        if current then
            assert(current.x <= previous.x and current.x >= -200, 'exit position reversed')
            assert(current.alpha >= previous.alpha and current.alpha <= 1, 'exit alpha reversed')
            previous, samples = current, samples + 1
        end
    end
    assert(samples > 2 and previous.x == -200 and previous.alpha == 1, 'exit did not reach its end state')
    exact(20, 20, 32)

    for _, disable in ipairs{'global', 'grab'} do
        popup.visible = true
        async.sleep(.3)
        assert(box('POPUP').alpha > 0)
        if disable == 'global' then animation.enabled = false
        else mousegrabber.run(function() return true end, 'left_ptr') end
        next_frame()
        local final = assert(box('POPUP'))
        assert(final.x == 0 and final.alpha == 0, disable .. ' did not finish entrance on next frame')
        exact(20, 20, 224)
        if disable == 'global' then animation.enabled = true else mousegrabber.stop() end
        popup.visible = false
        async.sleep(.3)
        assert(box('%-').alpha > 0)
        if disable == 'global' then animation.enabled = false
        else mousegrabber.run(function() return true end, 'left_ptr') end
        next_frame()
        local final_exit = box('%-')
        assert(not final_exit or final_exit.x == -200 and final_exit.alpha == 1,
            disable .. ' did not finish exit on next frame')
        exact(20, 20, 32)
        async.sleep(.05)
        assert(not box('%-'), 'disabled exit retained its element')
        if disable == 'global' then animation.enabled = true else mousegrabber.stop() end
    end

    local sized = wibox.container.background(nil, '#e0e0e0')
    sized.forced_width, sized.forced_height = 80, 60
    sized.animation = {forced_width = 1}
    local root = wibox.layout.fixed.horizontal(sized)
    root.animation = false
    local bar = wibox {screen = s, x = 400, y = 200, width = 200, height = 100,
        visible = false, shadow = false, bg = '#00000000', widget = root,
        animation = {visible = {duration = 1, enter = {'fade', 'grow'}, exit = {'grow', 'fade'}}}}
    bar.visible = true
    async.sleep(.3)
    mid = assert(box('WIBOX'))
    assert(mid.w > 0 and mid.w < 200 and mid.alpha > 0 and mid.alpha < 1, 'root policy suppressed drawin')
    sized.forced_width = 120
    next_frame()
    assert(dump():match('wibox.container.background[^\n]- 120x%d+'), 'descendant width did not snap: ' .. dump())
    assert(box('WIBOX').alpha > 0, 'widget policy finished drawin entrance')
    async.sleep(.9)
    assert(box('WIBOX').w == 200 and box('WIBOX').alpha == 0)
    bar.visible = false
    async.sleep(1.2)

    local moving = wibox {screen = s, x = 400, y = 300, width = 200, height = 100,
        visible = false, shadow = false, bg = '#00000000', widget = capture.leaf_widget(200, 100, '#e0e0e0'),
        animation = {visible = {duration = 1, enter = {'fade', 'slide_left'}}}}
    moving.visible = true
    async.sleep(.3)
    before = assert(box('WIBOX'))
    moving.x = 600
    next_frame()
    -- The first rendered frame may already carry one animation step, so it
    -- continues forward from `before`: no restart off-screen, no snap to the
    -- new x (a quarter of the remaining distance is several frames of motion),
    -- and the fade neither resets nor completes.
    previous = assert(box('WIBOX'))
    assert(previous.x >= before.x and previous.x < before.x + (600 - before.x) / 4,
        'interruption jumped on x\n' .. dump())
    assert(previous.y == before.y and previous.w == before.w and previous.h == before.h,
        'interruption changed the box\n' .. dump())
    assert(previous.alpha <= before.alpha and previous.alpha > 0, 'interruption jumped in alpha')
    for _ = 1, 6 do
        async.sleep(.2)
        local current = assert(box('WIBOX'))
        assert(current.x >= previous.x and current.x <= 600, 'retarget position reversed')
        assert(current.alpha <= previous.alpha, 'retarget fade reversed')
        previous = current
    end
    assert(previous.x == 600 and previous.alpha == 0, 'retarget did not settle')
    moving.visible = false
    async.sleep(.1)

    beautiful.animation_appear_duration = 1
    beautiful.animation_disappear_duration = 1
    beautiful.animation_tag_duration = .4
    local function spawn(class, effects)
        ruled.client.append_rule {
            rule = {class = class},
            properties = {animation = {appear = effects, disappear = {'fade', 'grow'}, tag = {'fade', 'slide_left'}},
                floating = true, border_width = 6, border_color = '#e0e0e0', shadow = false,
                titlebars_enabled = false, x = 300, y = 200, width = 200, height = 100},
        }
        local report, bounds, history = os.tmpname(), os.tmpname(), os.tmpname()
        awful.spawn{binary, class, report, '200', 'ff202020', '100', '200', '100', '0', '0', bounds, history}
        local c = assert(async.wait_for_client(class, 2))
        return c, {report, bounds, history}
    end
    local function finish(c, paths)
        c.animation = false
        c:kill()
        assert(async.wait_for_no_clients(2))
        for _, path in ipairs(paths) do os.remove(path) end
        async.sleep(.1)
    end
    local function sizes(path)
        local result, last = {}, nil
        for line in read(path):gmatch('[^\n]+') do
            if line ~= last then result[#result + 1], last = line, line end
        end
        assert(#result > 0, 'configure history is empty')
        return table.concat(result, '\n')
    end
    local plain, plain_paths = spawn('COMPOSE_PLAIN', 'grow')
    async.sleep(1.2)
    local plain_sizes = sizes(plain_paths[3])
    finish(plain, plain_paths)
    local c, paths = spawn('COMPOSE_CLIENT', {'fade', 'grow'})
    async.sleep(.3)
    mid = assert(box('CLIENT', 'COMPOSE_CLIENT'))
    assert(mid.w > 0 and mid.w < 212 and mid.alpha > 0 and mid.alpha < 1, dump())
    between(mid.x + 1, mid.y + math.floor(mid.h / 2))
    async.sleep(.9)
    settled = assert(box('CLIENT', 'COMPOSE_CLIENT'))
    assert(settled.alpha == 0 and settled.w == 212, dump())
    exact(settled.x + 1, settled.y + math.floor(settled.h / 2), 224)
    assert(sizes(paths[3]) == plain_sizes, 'composed configure sizes differ from grow: ' .. read(paths[3]) .. ' vs ' .. plain_sizes)
    local home = s.selected_tag
    local away = awful.tag.add('compose-away', {screen = s, layout = awful.layout.suit.tile})
    away:view_only()
    async.sleep(.12)
    mid = assert(box('%-'))
    assert(mid.x < settled.x and mid.alpha > 0 and mid.alpha < 1, 'composed tag exit did not run')
    async.sleep(.4)
    assert(not box('%-'), 'tag exit remained')
    home:view_only()
    async.sleep(.12)
    mid = assert(box('CLIENT', 'COMPOSE_CLIENT'))
    assert(mid.x < settled.x and mid.alpha > 0 and mid.alpha < 1, 'composed tag entrance did not run')
    async.sleep(.4)
    away:delete()
    c:kill()
    async.sleep(.3)
    mid = assert(box('%-'))
    assert(mid.w > 0 and mid.w < 212 and mid.alpha > 0 and mid.alpha < 1, 'client composed exit did not run')
    async.sleep(.9)
    assert(not box('%-'), 'client exit remained')
    for _, path in ipairs(paths) do os.remove(path) end
    local count = #warnings()
    c, paths = spawn('COMPOSE_DISABLED', {'grow', 'fade', 'slide_left', 'slide_right'})
    async.sleep(.3)
    assert(#warnings() == count + 1, 'client redeclarations repeated the conflict warning')
    c.animation = false
    next_frame()
    settled = assert(box('CLIENT', 'COMPOSE_DISABLED'))
    assert(settled.w == 212 and settled.alpha == 0, 'client disable did not finish on next frame')
    c.animation = {disappear = {'none', 'fade'}, tag = {'fade', 'grow'}}
    next_frame()
    c:kill()
    assert(async.wait_for_no_clients(2))
    async.sleep(.05)
    assert(not box('%-'), 'explicit none fell back to the tag exit')
    for _, path in ipairs(paths) do os.remove(path) end

    count = #warnings()
    popup.animation = {visible = {duration = .4, enter = {'fade', 'slide_left', 'slide_up', 'slide_up'}, exit = 'none'}}
    popup.visible = true
    async.sleep(.12)
    mid = assert(box('POPUP'))
    assert(mid.x < 0 and mid.y == 0 and mid.alpha > 0, 'refused pair lost its allowed effects')
    async.sleep(.4)
    local messages = warnings()
    assert(#messages == count + 1, 'conflicting directions did not warn once')
    assert(messages[#messages]:find('slide_left + slide_up conflict; slide_up is ignored, slide_left remains active', 1, true))
    popup.visible = false
    async.sleep(.1)
    for _, effects in ipairs{{'none', 'fade', 'fade'}, {'fade', 'none', 'none'}} do
        count = #warnings()
        popup.animation = {visible = {duration = .4, enter = effects}}
        popup.visible = true
        async.sleep(.12)
        assert((box('POPUP').alpha > 0) == (effects[1] == 'fade'), 'none conflict ignored first named')
        async.sleep(.4)
        assert(#warnings() == count + 1, 'none pair did not warn once')
        popup.visible = false
        async.sleep(.1)
    end
    count = #warnings()
    for _, effects in ipairs{{'fade', 'grow', 'slide_left'}, {'slide_left', 'collapse', 'fade', 'grow', 'fade'}} do
        popup.animation = {visible = {duration = .4, enter = effects}}
        popup.visible = true
        async.sleep(.12)
        mid = assert(box('POPUP'))
        assert(mid.x < 0 and mid.w > 0 and mid.w < 200 and mid.alpha > 0 and mid.alpha < 1,
            'three simultaneous effects did not run: ' .. dump())
        async.sleep(.4)
        assert(box('POPUP').w == 200 and box('POPUP').x == 0 and box('POPUP').alpha == 0)
        popup.visible = false
        async.sleep(.1)
    end
    assert(#warnings() == count, 'duplicates warned')
    for _, slide in ipairs{'slide_left', 'slide_right', 'slide_up', 'slide_down'} do
        for _, effect in ipairs{'fade', 'grow'} do
            popup.animation = {visible = {duration = .25, enter = {slide, effect}, exit = {effect, slide}}}
            popup.visible = true
            async.sleep(.08)
            mid = assert(box('POPUP'))
            if slide == 'slide_left' then assert(mid.x < 0, dump())
            elseif slide == 'slide_right' then assert(mid.x > 0 and mid.x < s.geometry.width, dump())
            elseif slide == 'slide_up' then assert(mid.y < 0, dump())
            else assert(mid.y > 0 and mid.y < s.geometry.height, dump()) end
            if effect == 'fade' then assert(mid.alpha > 0 and mid.alpha < 1 and mid.w == 200, dump())
            else assert(mid.w > 0 and mid.w < 200 and mid.alpha == 0, dump()) end
            async.sleep(.22)
            assert(box('POPUP').x == 0 and box('POPUP').y == 0 and box('POPUP').w == 200)
            popup.visible = false
            assert(async.wait_for_condition(function() return not box('POPUP') and not box('%-') end, .6, .01),
                'composed ' .. slide .. ' + ' .. effect .. ' exit remained: ' .. dump())
        end
    end
    wall:remove_screen(s)
    io.stderr:write('[PASS] composed boxes, pixels, interruption, retarget, configure sizes, disabling and conflicts\n')
    runner.done()
end)
