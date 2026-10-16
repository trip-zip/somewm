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
local shape = require('gears.shape')
local utils = require('_utils')
local binary = assert(utils.binary_or_skip('./build-test/test-transient-client'))
local pointer = assert(utils.binary_or_skip('./build-test/test-virtual-pointer-client'))
local s = screen[1]

local function dump()
    local text = awesome._clay_tree(s)
    assert(not text:find('[tree!=scene]', 1, true), text)
    assert(text:match('derived 0'), text)
    return text
end

local function bounds(line, field)
    local x, y, w, h = line:match(field .. ' (%-?%d+),(%-?%d+) (%d+)x(%d+)')
    if x then return {x = tonumber(x), y = tonumber(y), w = tonumber(w), h = tonumber(h)} end
end

local function frame(role, class)
    for line in dump():gmatch('[^\n]+') do
        if line:match('^%s*' .. role .. ' ') and (not class or line:find(class, 1, true)) then
            local box = bounds(line, 'box')
            if box then
                box.presented = bounds(line, 'presented') or box
                box.scale = tonumber(line:match('scale ([%d.]+)')) or 1
                box.fade = 1 - (tonumber(line:match('fade_alpha ([%d.]+)')) or 0)
                box.anchor = line:match('anchor (%w+)')
                return box
            end
        end
    end
end

local function next_frame()
    local old = assert(tonumber(dump():match('frames (%d+)')))
    assert(async.wait_for_condition(function()
        return tonumber(dump():match('frames (%d+)')) > old
    end, 1, .001), 'no rendered frame')
end

local function command(argv)
    local done, out, err, status
    awful.spawn.easy_async(argv, function(stdout, stderr, _, code)
        done, out, err, status = true, stdout, stderr, code
    end)
    assert(async.wait_for_condition(function() return done end, 3, .005), 'capture command timed out')
    assert(status == 0, table.concat(argv, ' ') .. ': ' .. tostring(err))
    return out
end

local function move(x, y)
    command{pointer, 'move', tostring(math.floor(x)), tostring(math.floor(y)), '1280', '720'}
end

local function shot()
    local image = surface(s.content)
    if utils.is_headless() then
        local path = os.tmpname() .. '.png'
        command{'grim', path}
        image = surface.load_uncached(path)
        os.remove(path)
    end
    return image
end

local function pixel(image, x, y, value)
    local r, g, b = capture.read(image, x, y)
    assert(r == value and g == value and b == value,
        string.format('pixel %d,%d: %d,%d,%d expected %d\n%s', x, y, r, g, b, value, dump()))
end

local function same_box(a, b)
    return a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h
end

local function border(image, final, bottom)
    local y = bottom and final.y + final.h - 1 or final.y + math.floor(final.h / 2)
    local left, right
    for x = final.x, final.x + final.w - 1 do
        local r, g, b = capture.read(image, x, y)
        if r > 240 and g < 15 and b > 240 then
            left, right = left or x, x
        end
    end
    assert(left and right, 'scaled border missing\n' .. dump())
    assert(left > final.x and right < final.x + final.w - 1, 'border did not scale')
    assert(left - final.x == final.x + final.w - 1 - right, 'border is not centered')
end

local function exact_picture(image, final)
    for y = final.y - 1, final.y + final.h do
        for x = final.x - 1, final.x + final.w do
            local edge = x == final.x or x == final.x + final.w - 1
                or y == final.y or y == final.y + final.h - 1
            local outside = x < final.x or x >= final.x + final.w or y < final.y or y >= final.y + final.h
            if edge and not outside then
                local r, g, b = capture.read(image, x, y)
                assert(r == 255 and g == 0 and b == 255, 'final border differs')
            else pixel(image, x, y, outside and 32 or 224) end
        end
    end
end

local function read(path)
    local f = assert(io.open(path, 'r'))
    local text = f:read('*a')
    f:close()
    return text
end

local function sizes(path)
    local result, previous = {}, nil
    for line in read(path):gmatch('[^\n]+') do
        if line ~= previous then result[#result + 1] = line end
        previous = line
    end
    assert(#result > 0, 'empty configure history')
    return table.concat(result, '\n')
end

runner.run_async(function()
    local wall = awful.wallpaper {screen = s, bg = '#202020'}
    mouse.coords{x = 1200, y = 650}
    local leaf = capture.leaf_widget(200, 100, '#e0e0e0')
    local popup = awful.popup {screen = s, x = 200, y = 200, visible = false,
        shadow = false, bg = '#00000000', border_width = 1, border_color = '#ff00ff',
        widget = leaf, animation = {visible = {duration = 1, enter = 'scale', exit = 'scale'}}}
    local final = {x = 199, y = 199, w = 202, h = 102}
    for _, effect in ipairs{'scale', 'scale_bottom'} do
        popup.animation = {visible = {duration = 1, enter = effect, exit = effect}}
        popup.visible = true
        async.sleep(.3)
        local mid = assert(frame('WIBOX'), dump())
        if effect == 'scale' then print('scale popup mid-flight:\n' .. dump()) end
        assert(same_box(mid, final), 'scale changed the slot\n' .. dump())
        assert(mid.scale > 0 and mid.scale < 1 and mid.fade == 1, dump())
        assert(mid.anchor == (effect == 'scale' and 'center' or 'bottom'), dump())
        local image = shot()
        pixel(image, 300, 250, 224)
        border(image, final, effect == 'scale_bottom')
        if effect == 'scale_bottom' then
            for _ = 1, 3 do
                async.sleep(.1)
                mid = assert(frame('WIBOX'), dump())
                assert(mid.presented.y + mid.presented.h == final.y + final.h, 'bottom anchor moved')
                image = shot()
                local r, g, b = capture.read(image, 300, final.y + final.h - 1)
                assert(r == 255 and g == 0 and b == 255, 'bottom border row moved')
            end
            async.sleep(.6)
        else async.sleep(.9) end
        assert(same_box(assert(frame('WIBOX'), dump()), final), dump())
        exact_picture(shot(), final)
        popup.animation = false
        popup.visible = false
        async.sleep(.05)
    end

    popup.animation = {visible = {duration = 1, enter = 'scale', exit = 'scale'}}
    popup.visible = true
    async.sleep(.3)
    local before = assert(frame('WIBOX'), dump()).scale
    popup.visible = false
    assert(async.wait_for_condition(function() return frame('%-') end, 1, .001))
    local previous = assert(frame('%-')).scale
    assert(math.abs(previous - before) < .15, 'exit restarted')
    while frame('%-') do
        next_frame()
        local current = frame('%-')
        if current then
            assert(current.scale <= previous, 'exit reversed')
            previous = current.scale
        end
    end
    pixel(shot(), 300, 250, 32)
    popup.visible = true
    async.sleep(.3)
    animation.enabled = false
    next_frame()
    assert(frame('WIBOX').scale == 1, 'disabled scale did not snap')
    exact_picture(shot(), final)
    animation.enabled = true
    popup.visible = false
    async.sleep(.3)
    animation.enabled = false
    next_frame()
    pixel(shot(), 300, 250, 32)
    async.sleep(.05)
    assert(not frame('%-'), 'disabled exit retained a carrier')
    animation.enabled = true

    for _, effects in ipairs{{'scale', 'fade'}, {'scale', 'slide_up'}, {'scale', 'slide_up', 'fade'}} do
        popup.animation = {visible = {duration = 1, enter = effects, exit = effects}}
        popup.visible = true
        async.sleep(.3)
        local mid = assert(frame('WIBOX'), dump())
        assert(mid.w == final.w and mid.h == final.h and mid.scale > 0 and mid.scale < 1, dump())
        local slide = effects[2] == 'slide_up'
        local fade = effects[#effects] == 'fade'
        assert(not slide or mid.y > -final.h and mid.y < final.y, dump())
        assert(not fade or math.abs(mid.fade - mid.scale) < .00001, dump())
        local image = shot()
        local p = mid.presented
        local r, g, b = capture.read(image, p.x + math.floor(p.w / 2), p.y + math.floor(p.h / 2))
        if fade then assert(r > 32 and r < 224 and r == g and g == b, 'composed scale did not blend')
        else assert(r == 224 and g == 224 and b == 224, 'slide lost scaled content') end
        async.sleep(.9)
        exact_picture(shot(), final)
        popup.animation = false
        popup.visible = false
        async.sleep(.05)
    end

    local text = wibox.widget.textbox('MMMM')
    text.font = 'Noto Sans Mono CJK KR 40'
    local bar = wibox {screen = s, x = 500, y = 300, width = 240, height = 100,
        visible = false, shadow = false, bg = '#202020', fg = '#e0e0e0', widget = text,
        animation = {visible = {duration = 1, enter = 'scale'}}}
    local entered = 0
    text:connect_signal('mouse::enter', function() entered = entered + 1 end)
    bar.visible = true
    async.sleep(.3)
    local function text_box()
        for line in dump():gmatch('[^\n]+') do
            if line:find('wibox.widget.textbox', 1, true) then return bounds(line, 'presented') or bounds(line, 'box') end
        end
        error('textbox missing')
    end
    local function glyph_rows(image)
        local rows = 0
        for y = 300, 399 do
            for x = 500, 739 do
                local r = capture.read(image, x, y)
                if r > 100 then rows = rows + 1; break end
            end
        end
        return rows
    end
    local small, rows = text_box(), glyph_rows(shot())
    move(501, 350)
    async.sleep(.015)
    assert(entered == 0, 'widget entered at the final edge')
    local p = assert(frame('WIBOX'), dump()).presented
    move(p.x + 2, p.y + p.h / 2)
    assert(async.wait_for_condition(function() return entered > 0 end, .1, .005), 'widget missed scaled edge\n' .. dump())
    move(1200, 650)
    async.sleep(.9)
    local large = text_box()
    assert(small.w < large.w and small.h < large.h, 'textbox dump did not scale')
    assert(rows > 0 and rows < glyph_rows(shot()), 'glyph rows did not scale')
    bar.visible = false
    async.sleep(.05)

    local popup_enters = 0
    leaf:connect_signal('mouse::enter', function() popup_enters = popup_enters + 1 end)
    popup.animation = {visible = {duration = 1, enter = 'fade', exit = 'fade'}}
    popup.visible = true
    async.sleep(.3)
    local fading = assert(frame('WIBOX'), dump())
    assert(fading.scale == 1 and fading.fade > 0 and fading.fade < 1, dump())
    move(250, 230)
    assert(async.wait_for_condition(function() return popup_enters > 0 end, .1, .005),
        'widget missed fade entrance\n' .. dump())
    move(1200, 650)
    async.sleep(.9)
    popup.visible = false
    async.sleep(.3)
    local exiting = assert(frame('%-'), dump())
    assert(exiting.fade > 0 and exiting.fade < 1, 'popup exit was not mid-flight\n' .. dump())
    local before_exit_hover = popup_enters
    move(250, 230)
    async.sleep(.1)
    assert(popup_enters == before_exit_hover, 'widget entered during its exit\n' .. dump())
    move(1200, 650)
    async.sleep(.8)
    assert(not frame('%-'), 'popup exit retained its picture')

    local rounded = wibox {screen = s, x = 500, y = 300, width = 200, height = 100,
        visible = false, shadow = false, bg = '#00000000',
        shape = function(cr, w, h) shape.rounded_rect(cr, w, h, 24) end,
        widget = capture.leaf_widget(200, 100, '#e0e0e0'),
        animation = {visible = {duration = 1, enter = 'scale'}}}
    rounded.visible = true
    async.sleep(.3)
    local function corners()
        local box = assert(frame('WIBOX'), dump())
        local image = shot()
        local p = box.presented
        local radius = 24 * box.scale
        pixel(image, p.x + 1, p.y + 1, 32)
        pixel(image, p.x + math.ceil(radius) + 2, p.y + 2, 224)
        local partial = false
        for y = p.y, p.y + math.ceil(radius) do
            for x = p.x, p.x + math.ceil(radius) do
                local red = capture.read(image, x, y)
                local alpha = (red - 32) / 192
                if alpha > .05 and alpha < .95 then partial = true end
            end
        end
        assert(partial, 'rounded clip has no antialiased corner coverage')
        return box.scale
    end
    assert(corners() < 1, 'corner sample was not mid-flight')
    async.sleep(.9)
    assert(corners() == 1, 'corner did not settle')
    rounded.visible = false
    async.sleep(.05)

    for _, effect in ipairs{'scale_top', 'scale_left', 'scale_right'} do
        popup.animation = {visible = {duration = 1, enter = effect}}
        popup.visible = true
        async.sleep(.3)
        local mid = assert(frame('WIBOX'), dump())
        local p = mid.presented
        assert(mid.scale > 0 and mid.scale < 1 and same_box(mid, final), dump())
        if effect == 'scale_top' then assert(p.y == final.y, 'top anchor moved')
        elseif effect == 'scale_left' then assert(p.x == final.x, 'left anchor moved')
        else assert(p.x + p.w == final.x + final.w, 'right anchor moved') end
        popup.animation = false
        popup.visible = false
        async.sleep(.05)
    end
    local function warnings()
        local count = 0
        for line in read(assert(os.getenv('SOMEWM_TEST_LOG'))):gmatch('[^\n]+') do
            if line:find('conflict;', 1, true) then count = count + 1 end
        end
        return count
    end
    for _, effects in ipairs{{'scale', 'grow'}, {'grow', 'scale'}, {'collapse', 'scale_top'},
            {'scale_bottom', 'scale_left'}, {'scale_right', 'collapse'}} do
        local count = warnings()
        popup.animation = {visible = {duration = 1, enter = effects}}
        popup.visible = true
        async.sleep(.3)
        local mid = assert(frame('WIBOX'), dump())
        if effects[1]:match('^scale') then
            assert(mid.scale > 0 and mid.scale < 1 and mid.w == final.w, 'first scale was lost')
        else assert(mid.scale == 1 and mid.w > 0 and mid.w < final.w, 'first grow was lost') end
        assert(warnings() == count + 1, 'size conflict did not warn once')
        popup.animation = false
        popup.visible = false
        async.sleep(.05)
    end

    move(1200, 650)
    beautiful.animation_appear_duration = 1
    local function spawn(class, effect)
        ruled.client.append_rule {rule = {class = class}, properties = {
            floating = true, x = 400, y = 250, width = 200, height = 100,
            titlebars_enabled = false, border_width = 1, border_color = '#ff00ff', shadow = false,
            animation = effect and {appear = effect} or false}}
        local paths = {os.tmpname(), os.tmpname(), os.tmpname()}
        awful.spawn{binary, class, paths[1], '200', 'ffe0e0e0', '100', '200', '100', '0', '0', paths[2], paths[3]}
        return assert(async.wait_for_client(class, 2)), paths
    end
    local function finish(c, paths)
        c.animation = false
        c:kill()
        assert(async.wait_for_no_clients(2))
        for _, path in ipairs(paths) do os.remove(path) end
        async.sleep(.05)
    end
    local plain, paths = spawn('SCALE_PLAIN')
    async.sleep(1.2)
    local expected, geometry = sizes(paths[3]), plain:geometry()
    finish(plain, paths)
    local c
    c, paths = spawn('SCALE_CLIENT', 'scale_right')
    local client_enters = 0
    c:connect_signal('mouse::enter', function() client_enters = client_enters + 1 end)
    async.sleep(.3)
    local mid = assert(frame('CLIENT', 'SCALE_CLIENT'))
    assert(mid.scale > 0 and mid.scale < 1 and mid.anchor == 'right', dump())
    local g = c:geometry()
    assert(g.width == geometry.width and g.height == geometry.height, 'scale changed client geometry')
    move(mid.x + 2, mid.y + mid.h / 2)
    async.sleep(.015)
    assert(client_enters == 0, 'client entered at the final edge')
    local p = assert(frame('CLIENT', 'SCALE_CLIENT')).presented
    move(p.x + 3, p.y + p.h / 2)
    assert(async.wait_for_condition(function() return client_enters > 0 end, .1, .005), 'client missed scaled edge')
    move(1200, 650)
    client.focus = nil
    async.sleep(.04)
    client.focus = c
    async.sleep(.04)
    mid = assert(frame('CLIENT', 'SCALE_CLIENT'))
    assert(mid.scale > 0 and mid.scale < 1, 'commit sample was not mid-flight')
    pixel(shot(), mid.x + mid.w + 3, mid.y + mid.h / 2, 32)
    async.sleep(.9)
    assert(sizes(paths[3]) == expected, 'scale changed configure sizes: ' .. read(paths[3]) .. ' vs ' .. expected)
    pixel(shot(), 450, 300, 224)
    beautiful.animation_tag_duration = .4
    c.animation = {tag = 'scale_bottom'}
    next_frame()
    local home = s.selected_tag
    local away = awful.tag.add('scale-away', {screen = s, layout = awful.layout.suit.tile})
    away:view_only()
    async.sleep(.12)
    local exiting = assert(frame('%-'), dump())
    assert(exiting.scale > 0 and exiting.scale < 1, 'tag exit did not scale')
    async.sleep(.4)
    assert(not frame('%-'), 'tag exit retained its frame')
    home:view_only()
    async.sleep(.12)
    mid = assert(frame('CLIENT', 'SCALE_CLIENT'))
    assert(mid.scale > 0 and mid.scale < 1 and mid.anchor == 'bottom', 'tag entrance did not scale')
    async.sleep(.4)
    pixel(shot(), 450, 300, 224)
    away:delete()
    finish(c, paths)
    c, paths = spawn('SCALE_SNAP', 'scale')
    async.sleep(.3)
    assert(frame('CLIENT', 'SCALE_SNAP').scale < 1)
    animation.enabled = false
    next_frame()
    assert(frame('CLIENT', 'SCALE_SNAP').scale == 1, 'client scale did not snap')
    local settled = assert(frame('CLIENT', 'SCALE_SNAP'))
    pixel(shot(), settled.x + 3, settled.y + 3, 224)
    assert(sizes(paths[3]) == expected, 'client snap changed configure sizes')
    animation.enabled = true
    finish(c, paths)
    wall:remove_screen(s)
    io.stderr:write('[PASS] scale boxes, pixels, anchors, input, glyphs, composition, interruption, snap and configure sizes\n')
    runner.done()
end)
