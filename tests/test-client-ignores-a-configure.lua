-- A tiled client that acknowledges a new size and commits a buffer at its
-- old size three times, as ghostty does once after a scale change, is sent
-- the size again until it draws it: it ends at its cell within three
-- seconds and the dump holds no CONFIGURE probe, so nothing records a
-- committed size that differs from the configured one. Its first
-- configure, the cell, is the one it answers late.
local runner = require('_runner')
local awful = require('awful')
local utils = require('_utils')
local GLib = require('lgi').GLib

local binary = assert(utils.binary_or_skip('./build-test/test-transient-client'))
local c, report, stale_at
local evidence = os.getenv('SOMEWM_EXAMPLE_EVIDENCE')

local function now() return GLib.get_monotonic_time() / 1000 end

-- The first dump line of a role, and its box.
local function line(dump, role)
    for l in dump:gmatch('[^\n]+') do
        if l:match('^%s*' .. role .. ' ') then
            local bw, bh = l:match(' box %-?%d+,%-?%d+ (%d+)x(%d+)$')
            return l, {width = tonumber(bw), height = tonumber(bh)}
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
        screen[1].selected_tag.layout = awful.layout.suit.tile
        report = os.tmpname()
        awful.spawn{binary, 'ignores_configure', report, '0', 'ff204060', '0', '0', '0', '0', '3'}
        return true
    end,
    -- The client acknowledged its cell and drew its old size.
    function(n)
        c = c or utils.find_client_by_class('ignores_configure')
        local dump = awesome._clay_tree(screen[1])
        local probe_line, probe = line(dump, 'CONFIGURE')
        if not probe_line then assert(n < 40, 'the client never committed its old size'); return end
        local _, surface = line(dump, 'SURFACE')
        local cw, ch = configured()
        assert(cw == probe.width and ch == probe.height, string.format(
            'configured %sx%s, probe %dx%d', tostring(cw), tostring(ch), probe.width, probe.height))
        assert(surface.width == 200 and surface.height == 200, string.format(
            'surface %dx%d, want the old 200x200', surface.width, surface.height))
        stale_at = now()
        io.stderr:write('[PASS] acknowledged ' .. cw .. 'x' .. ch .. ', drew 200x200: ' .. probe_line .. '\n')
        return true
    end,
    function()
        local dump = awesome._clay_tree(screen[1])
        local probe = line(dump, 'CONFIGURE')
        local _, frame = line(dump, 'CLIENT')
        local _, surface = line(dump, 'SURFACE')
        local cw, ch = configured()
        local g = c:geometry()
        local done = not probe and surface.width == cw and surface.height == ch
            and frame.width == cw and frame.height == ch and g.width == cw and g.height == ch
        if not done then
            assert(now() - stale_at < 3000, string.format(
                'after %d ms: probe %s, surface %dx%d, frame %dx%d, geometry %dx%d, configured %sx%s',
                math.floor(now() - stale_at), tostring(probe), surface.width, surface.height,
                frame.width, frame.height, g.width, g.height, tostring(cw), tostring(ch)))
            return
        end
        io.stderr:write(string.format('[PASS] at its cell %dx%d after %d ms, no CONFIGURE probe in the dump\n',
            g.width, g.height, math.floor(now() - stale_at)))
        if evidence then
            local out = assert(io.open(evidence .. '/client-ignores-a-configure.dump', 'w'))
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
}, {kill_clients = false, wait_per_step = 5})
