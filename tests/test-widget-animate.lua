local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local wibox = require('wibox')
local capture = require('_widget_capture')
local surface = require('gears.surface')
local utils = require('_utils')
local s = screen[1]
-- Every animation's duration. The pauses before mid-animation reads scale
-- with it, so the capture after one stays inside the animation on a slow
-- CI runner.
local seconds = 3

local function dump()
    local text = awesome._clay_tree(s)
    assert(text:find('output ', 1, true), 'missing published output')
    assert(not text:find('[tree!=scene]', 1, true), text)
    return text
end

-- One frame as a pixels(x, y) reader: s.content, plus one grim capture when
-- headless, so every read of a checkpoint sees the same moment.
local function shot()
    local content, width, header, data = surface(s.content)
    if utils.is_headless() then
        local path, done = os.tmpname(), false
        awful.spawn.easy_async({'grim', '-t', 'ppm', path}, function(_, stderr, _, code)
            assert(code == 0, stderr)
            local file = assert(io.open(path, 'rb'))
            data = file:read('*a')
            file:close()
            os.remove(path)
            done = true
        end)
        assert(async.wait_for_condition(function() return done end, 2, .01), 'grim timed out')
        width, header = data:match('^P6%s+(%d+)%s+%d+%s+255%s()')
        assert(width, 'grim did not produce P6')
    end
    return function(x, y)
        local red, green, blue = capture.read(content, x, y)
        local values = {red, green, blue}
        if data then
            local offset = header + (y * tonumber(width) + x) * 3
            for channel = 0, 2 do values[#values + 1] = data:byte(offset + channel) end
        end
        return values
    end
end

local function color_between(pixels, x, y)
    for _, value in ipairs(pixels(x, y)) do
        assert(value > 32 and value < 224, 'background did not interpolate: ' .. value .. '\n' .. dump())
    end
end

-- Poll check up to timeout seconds and return whether it held. A snap is
-- polled for one second, which a seconds-long animation cannot reach.
local function wait_until(timeout, check)
    for _ = 1, timeout * 20 do
        if check() then return true end
        async.sleep(.05)
    end
    return false
end

local function wait_color(x, y, expected, timeout)
    local values
    wait_until(timeout, function()
        values = shot()(x, y)
        for _, value in ipairs(values) do if value ~= expected then return false end end
        return true
    end)
    for _, value in ipairs(values) do assert(value == expected, 'background did not settle: ' .. value) end
end

local function fill_width()
    local text = dump()
    for line in text:gmatch('[^\n]+') do
        local width = line:match('box 0,50 (%d+)x20')
        if width and tonumber(width) < 200 then return tonumber(width) end
    end
    error('missing progress fill: ' .. text)
end

runner.run_async(function()
    local background = wibox.container.background(nil, '#202020')
    background.animation = {bg = seconds}
    background.forced_height = 50
    local progress = wibox.widget.progressbar()
    progress.value, progress.max_value = .2, 1
    progress.color, progress.background_color = '#00ff00', '#000000'
    progress.forced_height = 20
    progress.animation = {value = seconds}
    local parent = wibox.layout.fixed.vertical(background, progress)
    local bar = wibox {screen = s, x = 0, y = 0, width = 200, height = 70,
        visible = true, ontop = true, shadow = false, widget = parent}
    local sized = wibox.container.background(nil, '#000000')
    sized.forced_width, sized.forced_height = 80, 40
    sized.border_color, sized.border_width = '#202020', 2
    sized.animation = {border_color = seconds, border_width = seconds, forced_width = seconds, forced_height = seconds}
    local size_bar = wibox {screen = s, x = 700, y = 0, width = 200, height = 100,
        visible = true, ontop = true, shadow = false, widget = wibox.container.place(sized, "left", "top")}
    local slider = wibox.widget.slider()
    slider.bar_color, slider.bar_active_color = '#000000', '#00ff00'
    slider.handle_color, slider.handle_width = '#000000', 4
    slider.bar_height, slider.bar_margins, slider.value = 20, 0, 20
    slider.animation = {value = seconds}
    local slider_bar = wibox {screen = s, x = 950, y = 0, width = 200, height = 20,
        visible = true, ontop = true, shadow = false, widget = slider}
    wait_color(20, 20, 32, 2)
    background.bg, progress.value = '#e0e0e0', .8
    sized.forced_width, sized.forced_height = 160, 80
    sized.border_color, sized.border_width, slider.value = '#e0e0e0', 8, 80
    async.sleep(.3 * seconds)
    local pixels = shot()
    color_between(pixels, 20, 20)
    color_between(pixels, 701, 10)
    color_between(pixels, 703, 10)
    for _, value in ipairs(pixels(706, 10)) do assert(value == 0, 'border grew over the content: ' .. value) end
    local mid = dump()
    local sw, sh = mid:match('wibox.container.background[^\n]-box 700,0 (%d+)x(%d+)')
    assert(sw and tonumber(sw) > 80 and tonumber(sw) < 160
        and tonumber(sh) > 40 and tonumber(sh) < 80, 'forced sizes did not interpolate: ' .. mid)
    local slider_width
    for line in mid:gmatch('[^\n]+') do
        local width = line:match('box 950,0 (%d+)x20')
        if width and tonumber(width) < 200 then slider_width = tonumber(width) end
    end
    assert(slider_width and slider_width > 40 and slider_width < 160, 'slider fill did not interpolate: ' .. mid)
    local width = fill_width()
    assert(width > 40 and width < 160, 'fill did not interpolate: ' .. width)
    async.sleep(.7 * seconds)
    wait_color(20, 20, 224, 1)
    assert(wait_until(1, function() return fill_width() == 160 end), 'fill did not settle')
    wait_color(701, 10, 224, 1)
    wait_color(706, 10, 224, 1)
    assert(wait_until(1, function() return dump():find('box 700,0 160x80', 1, true) end),
        'forced sizes did not settle')
    size_bar.visible, slider_bar.visible = false, false
    parent.animation = false
    background.bg, progress.value = '#202020', .2
    wait_color(20, 20, 32, 1)
    assert(wait_until(1, function() return fill_width() == 40 end), 'ancestor did not suppress fill animation')
    parent.spacing = 10
    assert(wait_until(1, function() return dump():find('box 0,60 40x20', 1, true) end),
        'widget position did not snap')
    local debug = require('gears.debug')
    local original_warning, warnings = debug.print_warning, {}
    debug.print_warning = function(message)
        warnings[#warnings + 1] = message
        original_warning(message)
    end
    background.animation = {bg = 1, x = 1}
    async.sleep(.1)
    background.animation = {bg = 1, x = 1}
    async.sleep(.1)
    debug.print_warning = original_warning
    local count = 0
    for _, warning in ipairs(warnings) do
        if warning:find('animation.x', 1, true) and warning:find('changes snap', 1, true) then count = count + 1 end
    end
    assert(count == 1, 'unsupported property did not warn once')
    parent.animation = nil
    local plain = wibox.container.background(nil, '#202020')
    local one_shot = wibox {screen = s, x = 220, y = 0, width = 70, height = 50,
        visible = true, ontop = true, shadow = false, widget = plain}
    wait_color(240, 20, 32, 2)
    plain:animate {bg = '#e0e0e0', duration = seconds}
    async.sleep(.3 * seconds)
    color_between(shot(), 240, 20)
    one_shot.fg = "#ffffff"
    async.sleep(.2 * seconds)
    color_between(shot(), 240, 20)
    async.sleep(.5 * seconds)
    wait_color(240, 20, 224, 1)
    plain.bg = '#202020'
    wait_color(240, 20, 32, 1)
    plain.animation = false
    plain:animate {bg = '#e0e0e0', duration = seconds}
    wait_color(240, 20, 224, 1)
    assert(plain.animation == false, 'request replaced the disabled policy')
    plain.animation = nil
    assert(plain.animation == nil and type(plain.animate) == 'function', 'policy reset hid the method')
    one_shot.visible = false
    bar.visible = false

    local widgets = wibox.layout.fixed.vertical()
    for _ = 1, 250 do
        local widget = wibox.container.background(nil, '#202020')
        widget.forced_height = 2
        widget.animation = {bg = seconds}
        widgets:add(widget)
    end
    local budget = wibox {screen = s, x = 300, y = 0, width = 100, height = 500,
        visible = true, ontop = true, shadow = false, widget = widgets}
    wait_color(320, 499, 32, 2)
    local published = dump()
    assert(not published:find('context reinitialized', 1, true), published)
    for _, widget in ipairs(widgets.children) do widget.bg = '#e0e0e0' end
    async.sleep(.3 * seconds)
    dump()
    pixels = shot()
    for _, value in ipairs(pixels(320, 499)) do
        assert(value == 224, 'widget past the budget did not snap: ' .. value)
    end
    color_between(pixels, 320, 1)
    async.sleep(.7 * seconds)
    wait_color(320, 1, 224, 1)
    budget.visible = false
    runner.done()
end)
