-- An X11 client's WM_NORMAL_HINTS under tile: min and max bound its surface
-- with the protocol word; a base size alone bounds nothing.
local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local utils = require('_utils')
local example = require('_clay_example')
local s = screen[1]

if os.getenv("WLR_BACKENDS") == "headless" then
    return runner.skip("XWayland tests require visual mode (HEADLESS=0)")
end

local HINTS_CLIENT = utils.binary_or_skip('./build-test/test-x11-hints-client')
if not HINTS_CLIENT then return end
local GRAB_CLIENT = utils.binary_or_skip('./build-test/test-x11-grab-client')
if not GRAB_CLIENT then return end

local function wait_client(class)
    for _ = 1, 250 do
        local c = utils.find_client_by_class(class)
        if c then return c end
        async.sleep(.02)
    end
    error('client did not map: ' .. class)
end

runner.run_async(function()
    -- Workaround for a compositor defect: the first X client after the lazy
    -- XWayland start races its map against xwaylandready() and never maps
    -- compositor-side (fast minimal clients lose; xterm-sized ones win).
    -- Spawn and discard one client so the real one maps reliably; matched by
    -- name because the racy client never gets its class. Remove once the
    -- first-X11-client map race is fixed.
    do
        local warm = awful.spawn(string.format("%s /dev/null warmup_x11 0 0 50 50",
                                               GRAB_CLIENT))
        assert(type(warm) == "number", "warm-up spawn failed: " .. tostring(warm))
        local wc
        async.wait_for_condition(function()
            for _, cc in ipairs(client.get()) do
                if cc.name == "warmup_x11" then wc = cc; return true end
            end
        end, 10)
        assert(wc, "warm-up X client did not appear")
        os.execute("kill -9 " .. warm .. " 2>/dev/null")
        async.wait_for_condition(function() return not wc.valid end, 5)
        async.sleep(0.2)
    end

    s.selected_tag.layout = awful.layout.suit.tile
    awful.spawn {HINTS_CLIENT, 'x11_hints_minmax', 'minmax'}
    local minmax = wait_client('x11_hints_minmax')
    awful.spawn {HINTS_CLIENT, 'x11_hints_base', 'base'}
    local base = wait_client('x11_hints_base')
    assert(minmax.size_hints_honor and base.size_hints_honor, 'size_hints_honor defaults to true')
    async.wait_for_condition(function()
        return minmax.size_hints.min_width == 300 and base.size_hints.base_width == 300
    end, 10)

    awful.layout.arrange(s)
    async.sleep(.15)
    local dump = awesome._clay_tree(s)
    example.save('x11-size-hints-tile', dump)

    assert(dump:match('\n%s*CLIENT x11_hints_minmax w='), dump)
    assert(dump:match('\n%s*CLIENT x11_hints_base w='), dump)
    assert(not minmax.floating and not base.floating, dump)

    local line = assert(dump:match('SURFACE x11_hints_minmax [^\n]+'), dump)
    assert(line:find('w=grow>=300<=900 protocol h=grow>=200<=700 protocol', 1, true), dump)
    assert(tonumber(line:match('box %-?%d+,%-?%d+ %d+x(%d+)')) == 700, dump)
    local hints = minmax.size_hints
    assert(hints.min_width == 300 and hints.min_height == 200, dump)
    assert(hints.max_width == 900 and hints.max_height == 700, dump)

    line = assert(dump:match('SURFACE x11_hints_base [^\n]+'), dump)
    assert(line:find('w=grow h=grow ', 1, true) and not line:find('protocol', 1, true), dump)
    hints = base.size_hints
    assert(hints.min_width == nil and hints.max_width == nil, dump)
    assert(hints.base_width == 300 and hints.base_height == 200, dump)
    assert(dump:find('derived 0 legacy 0', 1, true), dump)

    minmax:kill()
    base:kill()
    async.wait_for_condition(function() return not minmax.valid and not base.valid end, 10)
    runner.done()
end)
