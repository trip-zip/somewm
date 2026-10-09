-- The bounds a toplevel is sent are the workarea, whatever it draws. A
-- tiled client that acknowledges its cell and commits its old size three times is
-- sent the cell again and takes it; the bounds it received with that
-- configure are the workarea, not the size it drew (GTK holds a window
-- inside its bounds, so bounds taken from a commit would keep it there).
local runner = require('_runner')
local awful = require('awful')
local utils = require('_utils')

local binary = assert(utils.binary_or_skip('./build-test/test-transient-client'))
local c, report, bounds

local function pair(path)
    local f = io.open(path)
    local text = f and f:read('*a') or ''
    if f then f:close() end
    local w, h = text:match('^(%-?%d+) (%-?%d+)')
    return tonumber(w), tonumber(h)
end

runner.run_steps({
    function()
        screen[1].selected_tag.layout = awful.layout.suit.tile
        report, bounds = os.tmpname(), os.tmpname()
        awful.spawn{binary, 'bounds_probe', report, '0', 'ff204060', '0', '0', '0', '0', '3', bounds}
        return true
    end,
    -- The client is at its cell after drawing its old size once; every
    -- configure it answered carried the workarea as its bounds.
    function(n)
        c = c or utils.find_client_by_class('bounds_probe')
        if not c then return end
        local cw, ch = pair(report)
        local bw, bh = pair(bounds)
        local g = c:geometry()
        local wa = screen[1].workarea
        assert(bw == nil or (bw == wa.width and bh == wa.height), string.format(
            'bounds %sx%s, workarea %dx%d (configured %sx%s, geometry %dx%d)',
            tostring(bw), tostring(bh), wa.width, wa.height, tostring(cw), tostring(ch),
            g.width, g.height))
        local settled = cw and g.width == cw and g.height == ch
            and not awesome._clay_tree(screen[1]):find('\n%s*CONFIGURE ')
        if not settled then assert(n < 60, 'the client never ended at its cell'); return end
        io.stderr:write(string.format('[PASS] at its cell %dx%d, bounds %dx%d = workarea\n',
            g.width, g.height, bw, bh))
        return true
    end,
    function()
        c:kill()
        os.remove(report)
        os.remove(bounds)
        return true
    end,
}, {kill_clients = false, wait_per_step = 5})
