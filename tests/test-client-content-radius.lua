-- Content corners reveal the frame color. Nil and zero retain the shape's
-- corners. Read screen.content and, on headless outputs, grim pixels.
local runner = require('_runner')
local awful = require('awful')
local utils = require('_utils')
local shot = require('_shape_mask_capture')
local color = require('gears.color')
local ruled = require('ruled')
local wallpaper, ink, border, bar_color = '#123456', '#204060', '#ff00ff', '#ffff00'
local x, y, w, h, radius, bar = 100, 100, 300, 200, 16, 24
local c, report, ruled_report, ruled_client
local enters, leaves, signals = 0, 0, 0
local evidence = os.getenv('SOMEWM_EXAMPLE_EVIDENCE')
local unchanged = {}

local function line(dump, role)
    return assert(dump:match('\n( *' .. role .. ' inner_radius [^\n]*)'), role .. ' missing: ' .. dump)
end

local function check_dump(name, r, background, titlebar, path)
    local dump = awesome._clay_tree(screen[1])
    local surface = line(dump, 'SURFACE')
    if r then
        assert(surface:find(' radii ' .. r, 1, true), surface)
    else
        assert(not surface:find(' radii ', 1, true), surface)
    end
    local frame = line(dump, 'CLIENT')
    if name == 'b' or name == 'd' then unchanged[name] = frame .. '\n' .. surface end
    if name == 'shape-zero' or name == 'zero' then
        local original = unchanged[name == 'shape-zero' and 'b' or 'd']
        assert(frame .. '\n' .. surface == original, 'zero changed the nil-radius declaration')
    end
    if path then assert(frame:find(' shape ', 1, true), frame) end
    local geometry = assert(frame:match(' box (.*)'))
    local fill
    for node in dump:gmatch('[^\n]+') do
        if node:find(path and ' CUSTOM ' or ' RECTANGLE ', 1, true)
                and node:find(' box ' .. geometry .. ' ', 1, true)
                and node:find(' client inner_radius', 1, true) then
            fill = node
        end
    end
    if name ~= 'fullscreen' then
        assert((fill ~= nil) == background, 'frame background: ' .. dump)
    end
    if titlebar then
        local top = line(dump, 'TITLEBAR')
        assert(not top:find(' radii ', 1, true), top)
        io.stderr:write('[' .. name .. '] ' .. top .. '\n')
    end
    io.stderr:write('[' .. name .. '] ' .. frame .. '\n[' .. name .. '] ' .. surface .. '\n')
    if fill then io.stderr:write('[' .. name .. '] ' .. fill .. '\n') end
    if evidence then
        local out = assert(io.open(evidence .. '/content-radius-' .. name .. '.dump', 'w'))
        out:write(dump)
        out:close()
    end
end

local steps = {
    function()
        screen[1].scale = 1
        root.wallpaper(color(wallpaper))
        screen[1].selected_tag.layout = awful.layout.suit.floating
        mouse.coords{x = 640, y = 360}
        report = os.tmpname()
        awful.spawn{'./build-test/test-transient-client', 'inner_radius', report, '0', 'ff204060'}
        return true
    end,
    function(n)
        c = utils.find_client_by_class('inner_radius')
        if not c then assert(n < 30, 'client did not map'); return end
        assert(c.content_radius == nil, 'content_radius defaults to nil')
        c.floating, c.shadow, c.border_width, c.border_color = true, false, 4, border
        c:geometry{x = x, y = y, width = w, height = h}
        c:connect_signal('property::content_radius', function() signals = signals + 1 end)
        for _, value in ipairs{-1, '16', false, {top_left = -1}} do
            assert(not pcall(function() c.content_radius = value end), 'invalid radius accepted')
        end
        assert(signals == 0, 'rejected values emitted a signal')
        c.content_radius = radius
        assert(c.content_radius == radius and signals == 1, 'radius setter or signal failed')
        c.content_radius = radius
        assert(signals == 1, 'unchanged radius emitted a signal')
        return true
    end,
}

local function case(name, setup, radii, background, points, titlebar, path)
    if setup then steps[#steps + 1] = function() setup(); return true end end
    shot.check_steps(steps, function()
        check_dump(name, radii, background, titlebar, path)
        return points()
    end)
end

local function points(outer, inner, bw, top)
    bw, top = bw or 4, top or 0
    return {{x, y, outer}, {x + bw + 1, y + bw + top + 1, inner},
        {x + bw + radius, y + bw + top + radius, ink},
        {x + w / 2, y + 1, bw > 0 and border or ink}}
end

case('a', nil, '16,16,16,16', true, function() return points(border, border) end)
-- Numeric shape clips the border and background to the same outer corners.
case('b', function() c.shape = 16; c.content_radius = nil end, '12,12,12,12', false,
    function() return points(wallpaper, border) end)
case('shape-zero', function() c.content_radius = 0 end, '12,12,12,12', false,
    function() return points(wallpaper, border) end)
case('c', function() c.content_radius = 16 end, '16,16,16,16', true,
    function()
        local p = points(wallpaper, border)
        p[#p + 1] = {x + 8, y + 6, border}
        return p
    end)
case('d', function() c.shape = nil; c.content_radius = nil end, nil, false,
    function() return points(border, ink) end)
case('zero', function() c.content_radius = 0 end, nil, false,
    function() return points(border, ink) end)
case('e', function()
    c.content_radius = 16
    awful.titlebar(c, {size = bar, bg_normal = bar_color, bg_focus = bar_color})
end, '16,16,16,16', true, function()
    local p = points(border, border, 4, bar)
    p[#p + 1] = {x + 4, y + 4, bar_color}
    return p
end, true)
case('f', function() awful.titlebar.hide(c, 'top'); c.border_width = 0 end,
    '16,16,16,16', true, function() return points(border, border, 0) end)
steps[#steps + 1] = function()
    c:connect_signal('mouse::enter', function() enters = enters + 1 end)
    c:connect_signal('mouse::leave', function() leaves = leaves + 1 end)
    mouse.coords{x = x, y = y}; mouse._fake_motion(0, 0)
    return true
end
steps[#steps + 1] = shot.wait(function()
    assert(enters == 1 and leaves == 0, 'cut corner did not enter the client frame')
end)
steps[#steps + 1] = function()
    mouse.coords{x = x + radius, y = y + radius}; mouse._fake_motion(0, 0)
    return true
end
steps[#steps + 1] = function()
    mouse.coords{x = x, y = y}; mouse._fake_motion(0, 0)
    return true
end
steps[#steps + 1] = function(n)
    if n < 3 then return end
    assert(enters == 1 and leaves == 0, 'moving between content and frame left the client')
    mouse.coords{x = 640, y = 360}; mouse._fake_motion(0, 0)
    return true
end
steps[#steps + 1] = shot.wait(function() assert(leaves == 1, 'outside frame did not leave client') end)

case('path', function()
    c.border_width = 4
    c.shape = function(cr, width, height)
        cr:move_to(0, 0); cr:line_to(width, 0); cr:line_to(width, height - 32)
        cr:line_to(width - 32, height); cr:line_to(0, height); cr:close_path()
    end
end, '16,16,16,16', true, function()
    local p = points(border, border)
    p[#p + 1] = {x + w + 3, y + h + 3, wallpaper}
    return p
end, false, true)
case('fullscreen', function()
    c.content_background_color = bar_color
    c.fullscreen = true
end, nil, false, function()
    return {{0, 0, ink}, {radius, radius, ink}}
end)
steps[#steps + 1] = function()
    ruled.client.append_rule {id = 'content-radius', rule = {class = 'inner_rule'},
        properties = {content_radius = 19, content_background_color = bar_color, titlebars_enabled = false}}
    ruled_report = os.tmpname()
    awful.spawn{'./build-test/test-transient-client', 'inner_rule', ruled_report, '0', 'ff204060'}
    return true
end
steps[#steps + 1] = function(n)
    ruled_client = utils.find_client_by_class('inner_rule')
    if not ruled_client then assert(n < 30, 'ruled client did not map'); return end
    assert(ruled_client.content_radius == 19, 'rule did not pass the number unchanged')
    assert(ruled_client.content_background_color == bar_color, 'rule did not set the fill color')
    io.stderr:write('[g] ruled.client content_radius = 19\n')
    ruled.client.remove_rule('content-radius')
    ruled_client:kill(); c:kill()
    os.remove(report); os.remove(ruled_report)
    return true
end
runner.run_steps(steps, {kill_clients = false})
