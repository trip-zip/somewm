-- A resize acknowledgment resumes publication of the latest solved geometry.
local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local utils = require('_utils')
local binary = assert(utils.binary_or_skip('./build-test/test-transient-client'))
local s = screen[1]

runner.run_async(function()
    local t = s.selected_tag
    t.layout = awful.layout.suit.tile
    t.gap, t.gap_single_client = 0, true
    local report = os.tmpname()
    awful.spawn{binary, 'GEOMETRY_AFTER_COMMIT', report}
    local c = assert(async.wait_for_client('GEOMETRY_AFTER_COMMIT', 2))
    c.floating, c.shadow, c.border_width = false, false, 0
    assert(async.wait_for_condition(function()
        return c:_clay_geometry_is_solved() and c.width == s.workarea.width
    end, 2, .01), 'initial client geometry did not settle')

    assert(awesome.kill(c.pid, 19)) -- SIGSTOP keeps the resize unacknowledged.
    local ok, err = pcall(function()
        local function solve(gap)
            t.gap = gap
            local wa = s.workarea
            local box = string.format('box %d,%d %dx%d', wa.x + gap, wa.y + gap,
                wa.width - 2 * gap, wa.height - 2 * gap)
            assert(async.wait_for_condition(function()
                local line = awesome._clay_tree(s):match('CLIENT GEOMETRY_AFTER_COMMIT [^\n]+')
                return line and line:find(box, 1, true)
            end, 2, .01), 'layout did not solve ' .. box)
        end
        solve(20)
        solve(40)
        assert(not c:_clay_geometry_is_solved(), 'pending resize did not defer geometry publication')
    end)
    assert(awesome.kill(c.pid, 18)) -- SIGCONT lets both configure responses arrive.
    assert(ok, err)
    assert(async.wait_for_condition(function()
        return c:_clay_geometry_is_solved()
    end, 2, .01), 'acknowledged resize left stale client geometry: ' .. awesome._clay_tree(s))
    local g, wa = c:geometry(), s.workarea
    assert(g.x == wa.x + 40 and g.y == wa.y + 40
        and g.width == wa.width - 80 and g.height == wa.height - 80,
        'client did not publish the latest layout')
    c:kill()
    os.remove(report)
    runner.done()
end)
