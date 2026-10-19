-- A tiled client that commits a buffer larger than its cell, here whole
-- 1000 pixel cells and never below one, so 1000x1000 against a cell 686
-- high, does not grow its frame, the row or the WORKAREA: the frame keeps
-- the cell, the drawing is cut at it, and the probe asks for the cell.
local runner = require('_runner')
local awful = require('awful')
local utils = require('_utils')

local binary = assert(utils.binary_or_skip('./build-test/test-transient-client'))
local bar, bw, cell = 30, 2, 1000
local c, report
local evidence = os.getenv('SOMEWM_EXAMPLE_EVIDENCE')

-- The first dump line matching a pattern, and its box.
local function line(dump, pattern)
    for l in dump:gmatch('[^\n]+') do
        if l:match(pattern) then
            local x, y, w, h = l:match(' box (%-?%d+),(%-?%d+) (%d+)x(%d+)')
            return l, {x = tonumber(x), y = tonumber(y), width = tonumber(w), height = tonumber(h)}
        end
    end
end

local function role(dump, name)
    return line(dump, '^%s*' .. name .. ' ')
end

local function show(b)
    return b and string.format('%d,%d %dx%d', b.x, b.y, b.width, b.height) or 'nil'
end

local function inside(inner, outer)
    return inner.x >= outer.x and inner.y >= outer.y and inner.x + inner.width <= outer.x + outer.width
        and inner.y + inner.height <= outer.y + outer.height
end

-- The surface's realized line, which notes a cut box.
local function realized_surface(dump)
    return line(dump, 'CUSTOM .* client larger_than_cell$')
        or line(dump, 'CUSTOM .* client larger_than_cell %[solved!=realized%]$')
end

-- The frame's lines, for the log.
local function frame_lines(dump)
    local out = {}
    for _, name in ipairs({'CLIENT', 'CHROME', 'PROBE_SLOT', 'SURFACE', 'CONFIGURE'}) do
        out[#out + 1] = tostring((role(dump, name)))
    end
    out[#out + 1] = tostring((realized_surface(dump)))
    return table.concat(out, '\n')
end

local function check(dump)
    local _, root = role(dump, 'Clay__RootContainer')
    local _, workarea = role(dump, 'WORKAREA')
    assert(workarea and inside(workarea, root), string.format('WORKAREA %s is not inside the root %s',
        show(workarea), show(root)))
    local _, frame = role(dump, 'CLIENT')
    assert(frame and inside(frame, workarea), string.format('CLIENT %s is not inside the WORKAREA %s',
        show(frame), show(workarea)))
    local _, probe = role(dump, 'CONFIGURE')
    local want = {x = frame.x + bw, y = frame.y + bw + bar, width = frame.width - 2 * bw,
        height = frame.height - 2 * bw - bar}
    assert(probe and probe.x == want.x and probe.y == want.y and probe.width == want.width
        and probe.height == want.height, string.format('CONFIGURE %s, want the cell %s',
            show(probe), show(want)))
    local realized = realized_surface(dump)
    local rx, ry, rw, rh = tostring(realized):match(' rbox (%-?%d+),(%-?%d+) (%d+)x(%d+)')
    local rbox = rx and {x = tonumber(rx), y = tonumber(ry), width = tonumber(rw), height = tonumber(rh)}
    assert(rbox and inside(rbox, frame), string.format('SURFACE rbox %s is not inside the CLIENT %s',
        show(rbox), show(frame)))
    local g, s = c:geometry(), c.screen.geometry
    assert(g.x >= s.x and g.y >= s.y and g.x + g.width + 2 * bw <= s.x + s.width
        and g.y + g.height + 2 * bw <= s.y + s.height, string.format(
            'c:geometry() %s is past the screen %s', show(g), show(s)))
    return frame, probe, rbox, g
end

runner.run_steps({
    function()
        screen[1].selected_tag.layout = awful.layout.suit.tile
        report = os.tmpname()
        awful.spawn{binary, 'larger_than_cell', report, '0', 'ff204060', '0', '0', '0', tostring(cell)}
        return true
    end,
    function(n)
        c = utils.find_client_by_class('larger_than_cell')
        if not c then assert(n < 30, 'client did not map'); return end
        c.border_width = bw
        awful.titlebar(c, {size = bar})
        mouse.coords{x = 1270, y = 710}
        return true
    end,
    function(n)
        local committed = c._committed_size
        if not (committed and committed.width == cell and committed.height == cell) then
            assert(n < 15, 'no committed size record of 1000x1000: ' .. (committed
                and committed.width .. 'x' .. committed.height or 'nil'))
            return
        end
        return true
    end,
    function(n)
        local dump = awesome._clay_tree(screen[1])
        local ok, frame, probe, rbox, g = pcall(check, dump)
        if not ok then
            assert(n < 15, tostring(frame) .. '\n' .. frame_lines(dump))
            return
        end
        io.stderr:write('[PASS] WORKAREA inside the root, CLIENT ' .. show(frame) .. ' inside the WORKAREA\n')
        io.stderr:write('[PASS] CONFIGURE ' .. show(probe) .. ' is the CLIENT less the border and the titlebar\n')
        io.stderr:write('[PASS] SURFACE rbox ' .. show(rbox) .. ' inside the CLIENT\n')
        io.stderr:write('[PASS] c:geometry() ' .. show(g) .. ' within the screen\n')
        io.stderr:write(frame_lines(dump) .. '\n')
        if evidence then
            local out = assert(io.open(evidence .. '/client-committed-larger-than-cell.dump', 'w'))
            out:write(dump)
            out:close()
        end
        return true
    end,
    function()
        c:kill()
        os.remove(report)
        return true
    end,
}, {kill_clients = false})
