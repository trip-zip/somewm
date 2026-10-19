-- A client that commits a size other than the one it was configured, here
-- whole 16 pixel cells as a terminal keeps them, is drawn at the size it
-- committed: the titlebar is the surface's width and the shape's corners
-- are on the surface's real corners. The configure still carries the box
-- the user or the layout asked for, and nothing bounces back. grim reads
-- the headless lanes (pixman and gles2); nested in a host only
-- screen.content is read.
local runner = require('_runner')
local awful = require('awful')
local utils = require('_utils')
local capture = require('_widget_capture')
local gsurface = require('gears.surface')
local gshape = require('gears.shape')
local gcolor = require('gears.color')

local wallpaper, client_color, bar_color = '#123456', '#204060', '#ffff00'
local x, y, w, h, r, bar, cell = 100, 50, 1000, 650, 24, 30, 16
local c, report, grim_done, grim_err, ppm, baseline, solved
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

-- The first dump line of a role, and its box.
local function line(dump, role)
    for l in dump:gmatch('[^\n]+') do
        if l:match('^%s*' .. role .. ' ') then
            local bx, by, bw_, bh = l:match(' box (%-?%d+),(%-?%d+) (%d+)x(%d+)$')
            return l, {x = tonumber(bx), y = tonumber(by), width = tonumber(bw_), height = tonumber(bh)}
        end
    end
end

local function configured()
    local f = io.open(report)
    local text = f and f:read('*a') or ''
    if f then f:close() end
    local cw, ch = text:match('^(%-?%d+) (%-?%d+)')
    return tonumber(cw), tonumber(ch)
end

runner.run_steps({
    function()
        root.wallpaper(gcolor(wallpaper))
        screen[1].selected_tag.layout = awful.layout.suit.floating
        report = os.tmpname()
        awful.spawn{'./build-test/test-transient-client', 'commits_smaller', report, '0', 'ff204060',
            '0', '0', '0', tostring(cell)}
        return true
    end,
    function(n)
        c = utils.find_client_by_class('commits_smaller')
        if not c then assert(n < 30, 'client did not map'); return end
        c.floating = true
        c.shadow = false
        c.border_width = 0
        awful.titlebar(c, {size = bar, bg_normal = bar_color, bg_focus = bar_color})
        c:geometry{x = x, y = y, width = w, height = h}
        gsurface.apply_shape_bounding(c, gshape.rounded_rect, r)
        -- The pointer image is in the output's pixels: park it off the client.
        mouse.coords{x = 1270, y = 710}
        return true
    end,
    wait(function()
        local dump = awesome._clay_tree(screen[1])
        local surface = line(dump, 'SURFACE')
        assert(surface and surface:find('w=fixed(992) protocol h=fixed(608) protocol', 1, true),
            'the surface leaf is not at the committed size yet: ' .. tostring(surface))
        assert(line(dump, 'CONFIGURE'), 'no configure probe in the dump')
        local g = c:geometry()
        assert(g.x == x and g.y == y and g.width == 992 and g.height == 608 + bar,
            string.format('geometry %d,%d %dx%d', g.x, g.y, g.width, g.height))
    end),
    function()
        local dump = awesome._clay_tree(screen[1])
        local surface = line(dump, 'SURFACE')
        io.stderr:write('[PASS] the surface leaf is the committed size: ' .. surface .. '\n')
        local _, titlebar = line(dump, 'TITLEBAR')
        assert(titlebar.width == 992, 'titlebar box ' .. titlebar.width .. ' wide, want 992')
        io.stderr:write('[PASS] the titlebar box is 992 wide\n')
        local g = c:geometry()
        io.stderr:write(string.format('[PASS] c:geometry() reads %d,%d %dx%d\n', g.x, g.y, g.width, g.height))
        local cw, ch = configured()
        assert(cw == 1000 and ch == 620, string.format('last configure %sx%s, want 1000x620',
            tostring(cw), tostring(ch)))
        io.stderr:write('[PASS] the last configure is the requested box 1000x620, not 992\n')
        baseline = {line(dump, 'SURFACE'), line(dump, 'CONFIGURE')}
        solved = 0
        screen[1]:connect_signal('clay::solved', function() solved = solved + 1 end)
        return true
    end,
    -- Ten further frames, each declaring the screen again.
    function(n)
        if solved < 10 then
            awful.layout.arrange(screen[1])
            assert(n < 100, 'ten frames did not solve')
            return
        end
        local dump = awesome._clay_tree(screen[1])
        assert(line(dump, 'SURFACE') == baseline[1], 'surface line changed: ' .. tostring(line(dump, 'SURFACE')))
        assert(line(dump, 'CONFIGURE') == baseline[2], 'probe line changed: ' .. tostring(line(dump, 'CONFIGURE')))
        local cw, ch = configured()
        assert(cw == 1000 and ch == 620, 'a configure followed: ' .. tostring(cw) .. 'x' .. tostring(ch))
        io.stderr:write('[PASS] after ' .. solved .. ' frames the surface and probe lines are unchanged\n')
        if evidence then
            local out = assert(io.open(evidence .. '/commits-smaller-floating.dump', 'w'))
            out:write(dump)
            out:close()
        end
        grim('commits-smaller')
        return true
    end,
    function(n)
        if not grim_done then assert(n < 40, 'grim did not finish'); return end
        assert(not grim_err, grim_err)
        local right, bottom = x + 992 - 1, y + bar + 608 - 1
        check({
            {right, bottom, wallpaper, 'surface bottom-right corner'},
            {right - r, bottom - r, client_color, 'one radius in from bottom-right'},
            {x, bottom, wallpaper, 'surface bottom-left corner'},
            {x + r, bottom - r, client_color, 'one radius in from bottom-left'},
            {x, y, wallpaper, 'titlebar top-left corner'},
            {x + r, y + 2, bar_color, 'titlebar one radius in, inside the arc'},
            {right + 2, y + 2 + r, wallpaper, 'past the titlebar right edge'},
            {right + 2, bottom - r, wallpaper, 'past the surface right edge'},
        }, 'commits-smaller')
        return true
    end,
    function()
        c.floating = false
        screen[1].selected_tag.layout = awful.layout.suit.tile
        return true
    end,
    wait(function()
        local dump = awesome._clay_tree(screen[1])
        local _, frame = line(dump, 'CLIENT')
        local chrome_line, chrome = line(dump, 'CHROME')
        local probe_line, probe = line(dump, 'CONFIGURE')
        assert(chrome and probe, 'no chrome or probe in the tiled dump')
        local cw, ch = configured()
        assert(cw == probe.width and ch == probe.height,
            string.format('last configure %sx%s, probe %dx%d', tostring(cw), tostring(ch),
                probe.width, probe.height))
        assert(frame.height == probe.height + bar and frame.width == probe.width,
            'the frame is not the slot')
        local committed_w, committed_h = math.floor(cw / cell) * cell, math.floor(ch / cell) * cell
        assert(committed_w ~= cw or committed_h ~= ch, 'the slot is whole cells, nothing to wrap')
        assert(chrome.x == frame.x and chrome.y == frame.y, 'the chrome is not at the slot origin')
        assert(chrome.width == committed_w and chrome.height == committed_h + bar,
            string.format('chrome %dx%d, want %dx%d', chrome.width, chrome.height,
                committed_w, committed_h + bar))
        local g = c:geometry()
        assert(g.width == committed_w and g.height == committed_h + bar, 'tiled geometry not read back')
        io.stderr:write(string.format('[PASS] tiled: frame keeps the slot %d,%d %dx%d, chrome %d,%d %dx%d at its origin, last configure %dx%d is the probe\n',
            frame.x, frame.y, frame.width, frame.height, chrome.x, chrome.y, chrome.width, chrome.height, cw, ch))
        if evidence then
            local out = assert(io.open(evidence .. '/commits-smaller-tiled.dump', 'w'))
            out:write(dump)
            out:close()
        end
        assert(chrome_line and probe_line)
    end),
    function()
        c.shape = nil
        c:kill()
        os.remove(report)
        return true
    end,
}, {kill_clients = false})
