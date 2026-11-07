-- Inner arcs blend the surface with its frame at integer and fractional
-- output scales. Four titlebars keep their square corners during updates.
local runner = require('_runner')
local awful = require('awful')
local utils = require('_utils')
local capture = require('_widget_capture')
local surface = require('gears.surface')
local color = require('gears.color')
local shot = require('_shape_mask_capture')
local c, report
local ink, wallpaper = {32, 64, 96}, '#123456'
local frame = {255, 0, 255}
local radius, bar = 18, 20
local steps = {}

local function rgb(hex)
    return {tonumber(hex:sub(2, 3), 16), tonumber(hex:sub(4, 5), 16), tonumber(hex:sub(6, 7), 16)}
end

local function near(got, want, message)
    for channel = 1, 3 do
        assert(math.abs(got[channel] - want[channel]) <= 3,
            message .. ': channel ' .. channel .. ' got ' .. got[channel] .. ', want ' .. want[channel])
    end
end

local function bounds()
    local dump = awesome._clay_tree(screen[1])
    local line = assert(dump:match('\n( *SURFACE radius_updates [^\n]*)'))
    local radii = table.concat({radius, radius, radius, radius}, ',')
    assert(line:find(' radii ' .. radii, 1, true), line)
    assert(not c._committed_size, 'client resize is pending')
    local x, y, w, h = line:match(' box (%S+),(%S+) (%S+)x(%S+)')
    local g = c:geometry()
    x, y, w, h = tonumber(x), tonumber(y), tonumber(w), tonumber(h)
    assert(x == g.x + c.border_width + bar and y == g.y + c.border_width + bar,
        'surface origin does not follow the titlebars')
    assert(w == g.width - 2 * bar and h == g.height - 2 * bar, 'surface size does not follow geometry')
    local count = 0
    for node in dump:gmatch('[^\n]+') do
        if node:match('TITLEBAR[%w_]* radius_updates ') then
            count = count + 1
            assert(not node:find(' radii ', 1, true), 'titlebar inherited content rounding: ' .. node)
        end
    end
    assert(count == 4, 'four titlebars must be present')
    return x, y, w, h
end

local function check(read, scale, label)
    local x, y, w, h = bounds()
    local left, top = math.floor(x * scale + .5), math.floor(y * scale + .5)
    local right, bottom = math.floor((x + w) * scale + .5) - 1, math.floor((y + h) * scale + .5) - 1
    local r = math.floor(radius * scale)
    for _, corner in ipairs{{left, top, 1, 1}, {right, top, -1, 1},
            {right, bottom, -1, -1}, {left, bottom, 1, -1}} do
        local function pixel(dx, dy)
            return {read(corner[1] + corner[3] * dx, corner[2] + corner[4] * dy)}
        end
        near(pixel(0, 0), frame, label .. ' cut corner')
        near(pixel(r, r), ink, label .. ' inside content')
        near(pixel(math.floor(r * .24), math.floor(r * .24)), frame, label .. ' outside scaled arc')
        near(pixel(math.floor(r * .4), math.floor(r * .4)), ink, label .. ' inside scaled arc')
        near(pixel(-2, -2), frame, label .. ' titlebar join')
        local blended = 0
        for dy = 1, r - 2 do
            for dx = 1, r - 2 do
                local p = pixel(dx, dy)
                -- Every arc pixel is a mixture of these two opaque colors.
                -- Wallpaper leakage or a dark fringe breaks the other channels.
                local channel = 1
                for i = 2, 3 do
                    if math.abs(ink[i] - frame[i]) > math.abs(ink[channel] - frame[channel]) then
                        channel = i
                    end
                end
                local coverage = (p[channel] - frame[channel]) / (ink[channel] - frame[channel])
                assert(coverage >= -.02 and coverage <= 1.02, label .. ' edge has a third color')
                near(p, {frame[1] + coverage * (ink[1] - frame[1]),
                    frame[2] + coverage * (ink[2] - frame[2]),
                    frame[3] + coverage * (ink[3] - frame[3])}, label .. ' antialiased edge')
                if coverage > .1 and coverage < .9 then blended = blended + 1 end
            end
        end
        assert(blended > 0, label .. ' arc has no antialiased pixels')
    end
    io.stderr:write('[PASS] ' .. label .. ': four square titlebars, four filled cuts and blended arcs\n')
end

local function stage(label, setup)
    local done, ppm, failure
    steps[#steps + 1] = function() setup(); return true end
    steps[#steps + 1] = shot.wait(function()
        local image = surface(screen[1].content)
        check(function(x, y) return capture.read(image, x, y) end, 1,
            label .. ' screen.content scale=' .. screen[1].scale)
        done, ppm, failure = false, nil, nil
        if not utils.is_headless() then done = true; return end
        local path = os.tmpname()
        awful.spawn.easy_async({'grim', '-o', screen[1].output.name, '-t', 'ppm', path}, function(_, err, _, code)
            if code ~= 0 then failure = err else
                local f = assert(io.open(path, 'rb')); ppm = f:read('*a'); f:close()
            end
            os.remove(path)
            done = true
        end)
    end)
    steps[#steps + 1] = function(n)
        if not done then assert(n < 40, 'grim did not finish'); return end
        assert(not failure, failure)
        if ppm then
            local width, _, header = ppm:match('^P6%s+(%d+)%s+(%d+)%s+255%s()')
            assert(width, 'not a P6 capture')
            check(function(x, y)
                local offset = header + (y * tonumber(width) + x) * 3
                return ppm:byte(offset, offset + 2)
            end, screen[1].scale, label .. ' grim scale=' .. screen[1].scale)
        end
        return true
    end
end

steps[#steps + 1] = function()
    root.wallpaper(color(wallpaper))
    screen[1].selected_tag.layout = awful.layout.suit.floating
    mouse.coords{x = 0, y = 0}
    report = os.tmpname()
    awful.spawn{'./build-test/test-transient-client', 'radius_updates', report, '0', 'ff204060'}
    return true
end
steps[#steps + 1] = function(n)
    c = utils.find_client_by_class('radius_updates')
    if not c then assert(n < 30, 'client did not map'); return end
    c.floating, c.shadow, c.animation = true, false, false
    c.shape, c.border_width = nil, 4
    for _, side in ipairs{'top', 'right', 'bottom', 'left'} do
        awful.titlebar(c, {position = side, size = bar, bg_normal = '#ff00ff', bg_focus = '#ff00ff'})
    end
    return true
end
for _, scale in ipairs{1, 1.5} do
    stage('initial', function()
        screen[1].scale = scale
        radius, frame = 18, rgb('#ff00ff')
        c.content_radius, c.border_color = radius, '#ff00ff'
        for _, side in ipairs{'top', 'right', 'bottom', 'left'} do
            awful.titlebar(c, {position = side, size = bar, bg_normal = '#ff00ff', bg_focus = '#ff00ff'})
        end
        c:geometry{x = 40, y = 40, width = 300, height = 220}
    end)
    stage('resize and radius', function()
        radius = 26
        c.content_radius = radius
        c:geometry{x = 60, y = 50, width = 340, height = 260}
    end)
    stage('frame color', function()
        frame = rgb('#17c589')
        c.border_color = '#17c589'
        for _, side in ipairs{'top', 'right', 'bottom', 'left'} do
            awful.titlebar(c, {position = side, size = bar, bg_normal = '#17c589', bg_focus = '#17c589'})
        end
    end)
    steps[#steps + 1] = function() c.fullscreen = true; return true end
    steps[#steps + 1] = shot.wait(function()
        local dump = awesome._clay_tree(screen[1])
        local node = assert(dump:match('\n( *SURFACE radius_updates [^\n]*)'))
        assert(not node:find(' radii ', 1, true), 'fullscreen still rounds the surface')
        assert(not dump:match('TITLEBAR[%w_]* radius_updates '), 'fullscreen still has titlebars')
        near({capture.read(surface(screen[1].content), 2, 2)}, ink, 'fullscreen corner')
    end)
    stage('leave fullscreen', function() c.fullscreen = false end)
end
steps[#steps + 1] = function()
    c:kill(); os.remove(report); screen[1].scale = 1
    return true
end
runner.run_steps(steps, {kill_clients = false})
