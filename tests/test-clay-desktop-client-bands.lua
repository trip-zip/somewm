-- A desktop-type client floats at its band below the flow root, attached to
-- the output; tiled, it declares like a normal client, in flow in its cell,
-- and is placed at the cell on the frame that declares it.
local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local utils = require('_utils')
local example = require('_clay_example')
local gtimer = require('gears.timer')
local s = screen[1]

if os.getenv("WLR_BACKENDS") == "headless" then
    return runner.skip("XWayland tests require visual mode (HEADLESS=0)")
end

local HINTS_CLIENT = utils.binary_or_skip('./build-test/test-x11-hints-client')
if not HINTS_CLIENT then return end

-- arrange is a delayed call: run it, so the frame declares what it described.
local function frame()
    awful.layout.arrange(s)
    gtimer.run_delayed_calls_now()
    awesome._test_redeclare()
    return awesome._clay_tree(s)
end

local function line(dump, role)
    return assert(dump:match('\n( *' .. role .. ' desk_client [^\n]+)'),
        'no ' .. role .. ' line:\n' .. dump)
end

local function box(l)
    local x, y, w, h = l:match(' box (%-?%d+),(%-?%d+) (%d+)x(%d+)$')
    assert(x, 'no box: ' .. l)
    return {x = tonumber(x), y = tonumber(y), width = tonumber(w), height = tonumber(h)}
end

local function same(a, b, what)
    assert(a.x == b.x and a.y == b.y and a.width == b.width and a.height == b.height,
        string.format('%s: want %d,%d %dx%d, have %d,%d %dx%d', what,
            b.x, b.y, b.width, b.height, a.x, a.y, a.width, a.height))
end

local function inside(a, b, what)
    assert(a.x >= b.x and a.y >= b.y and a.x + a.width <= b.x + b.width
        and a.y + a.height <= b.y + b.height, what .. ' not inside its frame')
end

local function header(dump)
    assert(dump:find('\n  roots flow %d+ floating %d+ derived 0 legacy 0\n'),
        'header not derived 0 legacy 0')
    assert(not dump:find('[tree!=scene]', 1, true), 'tree and scene differ')
end

runner.run_async(function()
    -- Workaround for a compositor defect: the first X client after the lazy
    -- XWayland start races its map against xwaylandready() and never maps
    -- compositor-side. Spawn and discard one client so the real one maps
    -- reliably; matched by name because the racy client never gets its class.
    do
        local warm = awful.spawn {HINTS_CLIENT, 'warmup_x11', 'base'}
        assert(type(warm) == "number", "warm-up spawn failed: " .. tostring(warm))
        local wc
        async.wait_for_condition(function()
            for _, cc in ipairs(client.get()) do
                if cc.name == "warmup_x11" then wc = cc; return true end
            end
        end, 10)
        assert(wc, "warm-up X client did not appear")
        awesome.kill(warm, 9)
        async.wait_for_condition(function() return not wc.valid end, 5)
        async.sleep(0.2)
    end

    s.selected_tag.layout = awful.layout.suit.tile
    s.selected_tag.gap = 0
    local bar = awful.wibar {screen = s, position = 'top', height = 32}
    local pid = awful.spawn {HINTS_CLIENT, 'desk_client', 'desktop'}
    assert(type(pid) == "number", "spawn failed: " .. tostring(pid))
    local c
    async.wait_for_condition(function()
        c = utils.find_client_by_class('desk_client')
        return c and c.type == 'desktop'
    end, 10)
    assert(c and c.type == 'desktop', 'no desktop-type client desk_client')
    assert(c.floating == true, 'a desktop-type client floats by default')
    c.shadow = false
    c.border_width = 1

    -- Frame 1: floating, a root below the flow root attached to the output.
    local dump = frame()
    local cl, sl = line(dump, 'CLIENT'), line(dump, 'SURFACE')
    assert(cl:find('^  CLIENT') and cl:find(' attach OUTPUT offset %S+ band %-6 '),
        'floating CLIENT: ' .. cl)
    assert(sl:find(' attach PARENT offset %S+ band %-6 '), 'floating SURFACE: ' .. sl)
    local g, bw = c:geometry(), c.border_width
    same(box(cl), {x = g.x, y = g.y, width = g.width + 2 * bw, height = g.height + 2 * bw},
        'floating CLIENT box')
    inside(box(sl), box(cl), 'floating SURFACE')
    header(dump)
    example.check('desktop-client-floating', dump)
    io.stderr:write('[PASS] floating desktop client: OUTPUT band -6\n')

    -- Frame 2: tiled, the first frame with the cell.
    c.floating = false
    dump = frame()
    cl, sl = line(dump, 'CLIENT'), line(dump, 'SURFACE')
    io.stderr:write('frame 2 CLIENT: ', cl, '\nframe 2 SURFACE: ', sl, '\n')
    assert(dump:find('\n      WORKAREA [^\n]+\n        CLIENT desk_client ') and not cl:find(' band '),
        'tiled CLIENT not in flow under WORKAREA: ' .. cl)
    same(box(cl), s.workarea, 'tiled CLIENT box')
    same(box(cl), {x = 0, y = 32, width = 1280, height = 688}, 'tiled CLIENT box')
    assert(sl:find(' attach PARENT offset %S+ band 0 '), 'tiled SURFACE: ' .. sl)
    inside(box(sl), box(cl), 'tiled SURFACE')
    header(dump)
    example.check('desktop-client-tiled', dump)
    io.stderr:write('[PASS] tiled desktop client: in flow at its cell on its first frame\n')

    -- Frame 3: the bar hides, the workarea starts at y 0.
    bar.visible = false
    dump = frame()
    cl, sl = line(dump, 'CLIENT'), line(dump, 'SURFACE')
    same(box(cl), {x = 0, y = 0, width = 1280, height = 720}, 'moved CLIENT box')
    inside(box(sl), box(cl), 'moved SURFACE')
    assert(box(sl).y < 32, 'SURFACE did not move with its frame: ' .. sl)
    header(dump)
    example.save('desktop-client-moved', dump)
    assert(awesome._test_redeclare() == 0, 'unchanged frame did not settle')
    io.stderr:write('[PASS] tiled desktop client moves with the workarea on the same frame\n')

    awesome.kill(pid, 9)
    async.wait_for_condition(function() return not c.valid end, 5)
    runner.done()
end)
