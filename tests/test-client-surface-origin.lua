-- Changing the window origin within a surface must refresh an unchanged clip.
local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local utils = require('_utils')
local capture = require('_widget_capture')
local surface = require('gears.surface')
local binary = utils.binary_or_skip('./build-test/test-csd-state-client')
if not binary then return end

runner.run_async(function()
    local report = os.tmpname()
    local pid = awful.spawn {binary, '--geometry-offset', report}
    local c
    assert(async.wait_for_condition(function()
        c = utils.find_client_by_class('csd_test')
        return c ~= nil
    end, 2, .02), 'client did not map')
    c.floating, c.border_width, c.shadow, c.animation = true, 0, false, false
    local s = c.screen
    c:geometry {x = s.geometry.x + 100, y = s.geometry.y + 100, width = 400, height = 300}

    local function state()
        local f = assert(io.open(report))
        local values = {f:read('*n', '*n', '*n', '*n', '*n', '*n')}
        f:close()
        return values
    end

    local function settled(origin, commits)
        assert(async.wait_for_condition(function()
            local v, g = state(), c:geometry()
            return v[1] and v[1] > (commits or 0) and v[3] == origin and v[4] == origin
                and v[5] == g.width and v[6] == g.height
        end, 2, .02), 'client did not commit the expected window geometry')
        async.sleep(.15)
    end

    local function edges()
        local g = c:geometry()
        local img = surface(root.content())
        for _, point in ipairs({{50, 2, '#ff0000'}, {2, 50, '#00ff00'}}) do
            local x, y = g.x + point[1], g.y + point[2]
            local r, green, b = capture.read(img, x, y)
            local got = string.format('#%02x%02x%02x', r, green, b)
            assert(got == point[3], 'surface edge: expected ' .. point[3] .. ', got ' .. got)
            mouse.coords {x = x, y = y}
            assert(mouse.object_under_pointer() == c, 'surface edge lost input')
        end
    end

    settled(20)
    edges()
    for _, floating in ipairs({true, false}) do
        c.floating = floating
        async.sleep(.2)
        for _, origin in ipairs({0, 20}) do
            local before, geometry = state(), c:geometry()
            awesome.kill(pid, 28) -- SIGWINCH commits a different origin at the same size.
            settled(origin, before[1])
            edges()
            utils.assert_geometry(c:geometry(), geometry)
            assert(state()[2] == before[2], 'origin-only commit caused a configure')
        end
    end

    c.floating = true
    for _ = 1, 2 do
        c.maximized = true
        c:raise()
        settled(0)
        edges()
        c.maximized = false
        settled(20)
        edges()
    end
    awesome._test_redeclare()
    assert(awesome._test_redeclare() == 0, 'unchanged surface mutated the scene')
    c:kill()
    assert(async.wait_for_condition(function() return not c.valid end, 2, .02))
    os.remove(report)
    runner.done()
end)
