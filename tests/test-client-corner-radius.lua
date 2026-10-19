-- A client shaped with a rounded rectangle shows the wallpaper at its
-- corner and its own colour one radius in, read through grim (the output's
-- pixels) and through screen.content; a pointer at the corner is not on
-- the client. With a titlebar, the bar takes the top corners and the
-- surface keeps the bottom ones. grim reads the headless lanes (pixman and
-- gles2); nested in a host, the nested output is not presented, so only
-- screen.content is read there.
local runner = require('_runner')
local awful = require('awful')
local utils = require('_utils')
local capture = require('_widget_capture')
local gsurface = require('gears.surface')
local gshape = require('gears.shape')
local gcolor = require('gears.color')

local wallpaper, client_color, bar_color = '#123456', '#204060', '#ffff00'
local x, y, w, h, r, bar = 100, 100, 300, 200, 24, 24
local c, report, grim_done, grim_err, ppm
local entered, left = 0, 0
local evidence = os.getenv('SOMEWM_EXAMPLE_EVIDENCE')

local function content_pixel(px, py)
    local red, green, blue = capture.read(gsurface(screen[1].content), px, py)
    return string.format('#%02x%02x%02x', red, green, blue)
end

-- One pixel of a binary PPM (P6) as grim -t ppm writes it.
local function ppm_pixel(data, px, py)
    local width, height, header = data:match('^P6%s+(%d+)%s+(%d+)%s+255%s()')
    assert(width, 'not a P6 ppm')
    assert(px < tonumber(width) and py < tonumber(height), 'pixel outside the capture')
    local at = header + (py * tonumber(width) + px) * 3
    return string.format('#%02x%02x%02x', data:byte(at, at + 2))
end

local function grim(name)
    local path = os.tmpname()
    grim_done, grim_err, ppm = false, nil, nil
    if not utils.is_headless() then
        grim_done = true
        return
    end
    awful.spawn.easy_async({'grim', '-t', 'ppm', path}, function(_, stderr, _, code)
        if code ~= 0 then
            grim_err = 'grim exit ' .. tostring(code) .. ': ' .. tostring(stderr)
        else
            local f = assert(io.open(path, 'rb'))
            ppm = f:read('*a')
            f:close()
            if evidence then
                local out = assert(io.open(evidence .. '/' .. name .. '.ppm', 'wb'))
                out:write(ppm)
                out:close()
            end
        end
        os.remove(path)
        grim_done = true
    end)
end

-- Both readers agree with the wanted colour at every point; the values
-- read go beside the capture when evidence is saved.
local function check(points, name)
    local lines = {}
    for _, p in ipairs(points) do
        local content = content_pixel(p[1], p[2])
        local captured = ppm and ppm_pixel(ppm, p[1], p[2]) or 'not captured'
        lines[#lines + 1] = string.format('%s at %d,%d: content %s grim %s want %s',
            p[4], p[1], p[2], content, captured, p[3])
        assert(content == p[3], string.format('%s: screen.content at %d,%d is %s, want %s (%s)',
            name, p[1], p[2], content, p[3], p[4]))
        assert(not ppm or captured == p[3], string.format('%s: grim at %d,%d is %s, want %s (%s)',
            name, p[1], p[2], captured, p[3], p[4]))
        io.stderr:write('[PASS] ' .. name .. ' ' .. lines[#lines] .. '\n')
    end
    if evidence then
        local out = assert(io.open(evidence .. '/' .. name .. '.pixels', 'w'))
        out:write(table.concat(lines, '\n'), '\n')
        out:close()
    end
end

local function wait(fn)
    return function(n)
        local ok, err = pcall(fn)
        if ok then return true end
        assert(n < 40, err)
    end
end

runner.run_steps({
    function()
        root.wallpaper(gcolor(wallpaper))
        screen[1].selected_tag.layout = awful.layout.suit.floating
        report = os.tmpname()
        awful.spawn{'./build-test/test-transient-client', 'corner_client', report, '0', 'ff204060'}
        return true
    end,
    function(n)
        c = utils.find_client_by_class('corner_client')
        if not c then assert(n < 30, 'client did not map'); return end
        c.floating = true
        c.shadow = false
        c.border_width = 0
        c:geometry{x = x, y = y, width = w, height = h}
        gsurface.apply_shape_bounding(c, gshape.rounded_rect, r)
        assert(type(c.shape) == 'function', 'apply_shape_bounding sets client.shape')
        -- The pointer image is in the output's pixels: park it off the client.
        mouse.coords{x = 640, y = 360}
        return true
    end,
    wait(function()
        local g = c:geometry()
        assert(g.x == x and g.y == y and g.width == w and g.height == h, 'geometry pending')
        assert(content_pixel(x, y) == wallpaper, 'corner not cut yet')
        assert(content_pixel(x + r, y + r) == client_color, 'client not painted yet')
        assert(awesome._clay_tree(screen[1]):find(' radii 24,24,24,24', 1, true),
            'the surface leaf declares its radii')
        grim('client-corner-radius')
    end),
    function(n)
        if not grim_done then assert(n < 40, 'grim did not finish'); return end
        assert(not grim_err, grim_err)
        check({
            {x, y, wallpaper, 'top-left corner'},
            {x + r, y + r, client_color, 'one radius in'},
            {x + w - 1, y + h - 1, wallpaper, 'bottom-right corner'},
            {x + w - 1 - r, y + h - 1 - r, client_color, 'one radius in from bottom-right'},
        }, 'shaped')
        return true
    end,
    -- The compositor's pointer path: mouse::enter and mouse::leave on the
    -- client follow what its hit test finds under the pointer. coords warps
    -- the pointer; the zero motion runs the path a device motion runs.
    function()
        c:connect_signal('mouse::enter', function() entered = entered + 1 end)
        c:connect_signal('mouse::leave', function() left = left + 1 end)
        mouse.coords{x = x + r, y = y + r}
        mouse._fake_motion(0, 0)
        return true
    end,
    wait(function() assert(entered == 1 and left == 0, 'one radius in enters the client') end),
    function()
        mouse.coords{x = x, y = y}
        mouse._fake_motion(0, 0)
        return true
    end,
    wait(function()
        assert(left == 1, 'the corner pixel leaves the client: nothing of it is there')
        io.stderr:write('[PASS] pointer one radius in enters the client, at the corner it leaves\n')
    end),
    function()
        mouse.coords{x = 640, y = 360}
        awful.titlebar(c, {size = bar, bg_normal = bar_color, bg_focus = bar_color})
        return true
    end,
    wait(function()
        local g = c:geometry()
        assert(g.height == h + bar, 'titlebar not added yet')
        assert(content_pixel(x, y) == wallpaper, 'titlebar corner not cut yet')
        assert(content_pixel(x + r, y + bar + 1) == client_color, 'surface not painted yet')
        local dump = awesome._clay_tree(screen[1])
        assert(dump:find(' radii 24,24,0,0', 1, true), 'the titlebar declares the top corners')
        assert(dump:find(' radii 0,0,24,24', 1, true), 'the surface declares the bottom corners')
        grim('client-corner-radius-titlebar')
    end),
    function(n)
        if not grim_done then assert(n < 40, 'grim did not finish'); return end
        assert(not grim_err, grim_err)
        check({
            {x, y, wallpaper, 'titlebar top-left corner'},
            {x + r, y + 2, bar_color, 'titlebar one radius in, inside the arc'},
            {x + 6, y + 6, wallpaper, 'titlebar 6 in from its corner, outside a 24 arc'},
            {x, y + bar, client_color, 'surface top-left corner, not cut'},
            {x, y + bar + h - 1, wallpaper, 'surface bottom-left corner'},
            {x + r, y + bar + h - 1 - r, client_color, 'surface one radius in from bottom-left'},
        }, 'titlebar')
        return true
    end,
    function()
        c.shape = nil
        return true
    end,
    wait(function()
        assert(c.shape == nil, 'shape reads nil')
        assert(content_pixel(x, y) == bar_color, 'square again')
        io.stderr:write('[PASS] shape nil draws the square corner again\n')
    end),
    function()
        c:kill()
        os.remove(report)
        return true
    end,
}, {kill_clients = false})
