-- A bordered wibox or popup that grows in or out shows its content only inside
-- the growing frame, not at its settled size behind it.
local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local wibox = require('wibox')
local capture = require('_widget_capture')
local surface = require('gears.surface')
local utils = require('_utils')
local s = screen[1]

local function dump()
    return awesome._clay_tree(s)
end

local function box(role)
    for line in dump():gmatch('[^\n]+') do
        if line:match('^%s*' .. role .. ' ') then
            local x, y, w, h = line:match('box (%-?%d+),(%-?%d+) (%d+)x(%d+)')
            if x then return {x = tonumber(x), y = tonumber(y), w = tonumber(w), h = tonumber(h)} end
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

local function exact(x, y, expected, what)
    for _, value in ipairs(pixels(x, y)) do
        assert(value == expected, what .. ': pixel ' .. value .. ' expected ' .. expected .. '\n' .. dump())
    end
end

-- Mid-transition the frame is smaller than settled: the settled content's
-- far corner lies outside it and shows the wallpaper; the near corner shows
-- the content.
local function clipped(role, corner, what)
    local mid = assert(box(role), what .. ': no ' .. role .. '\n' .. dump())
    assert(mid.w > 30 and mid.h > 30 and mid.x + mid.w <= corner.x and mid.y + mid.h <= corner.y,
        what .. ': frame not mid-grow\n' .. dump())
    exact(mid.x + 10, mid.y + 10, 224, what .. ' near corner')
    exact(corner.x, corner.y, 32, what .. ' far corner')
end

runner.run_async(function()
    local wall = awful.wallpaper {screen = s, bg = '#202020'}
    mouse.coords{x = 1200, y = 650}
    local policy = {visible = {duration = 1, enter = 'grow', exit = 'grow'}}

    local bar = wibox {screen = s, x = 400, y = 200, width = 200, height = 100,
        visible = false, shadow = false, bg = '#00000000', border_width = 4, border_color = '#a0a0a0',
        widget = capture.leaf_widget(200, 100, '#e0e0e0'), animation = policy}
    local far = {x = 400 + 190, y = 200 + 90}
    bar.visible = true
    async.sleep(.3)
    clipped('WIBOX', far, 'wibox entrance')
    async.sleep(.9)
    exact(far.x, far.y, 224, 'wibox settled')
    bar.visible = false
    async.sleep(.3)
    clipped('%-', far, 'wibox exit')
    async.sleep(.9)

    local popup = awful.popup {screen = s, placement = awful.placement.top_left, visible = false,
        shadow = false, bg = '#00000000', border_width = 4, border_color = '#a0a0a0',
        widget = capture.leaf_widget(200, 100, '#e0e0e0'), animation = policy}
    far = {x = 4 + 190, y = 4 + 90}
    popup.visible = true
    async.sleep(.3)
    clipped('POPUP', far, 'popup entrance')
    async.sleep(.9)
    exact(far.x, far.y, 224, 'popup settled')
    popup.visible = false
    async.sleep(.3)
    clipped('%-', far, 'popup exit')
    async.sleep(.9)

    wall:remove_screen(s)
    io.stderr:write('[PASS] grown drawins clip their content to the frame\n')
    runner.done()
end)
