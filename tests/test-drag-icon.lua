---------------------------------------------------------------------------
--- A mapped drag icon was omitted because declare.c required unset icon data.
--- The icon must appear while dragging and disappear after release.
---------------------------------------------------------------------------

local runner = require("_runner")
local async = require("_async")
local awful = require("awful")
local utils = require("_utils")

local CLIENT = utils.binary_or_skip("./build-test/test-pointer-logger")
local POINTER = utils.binary_or_skip("./build-test/test-virtual-pointer-client")
if not CLIENT or not POINTER then return runner.skip("test helpers not built") end

runner.run_async(function()
    awful.spawn({ CLIENT, "--app-id", "drag_icon", "--drag-icon" })
    local c = assert(async.wait_for_client("drag_icon", 5), "drag client did not appear")
    c.floating = true
    c:geometry({ x = 100, y = 200, width = 400, height = 300 })
    assert(async.wait_for_condition(function()
        local g = c:geometry()
        return g.x == 100 and g.y == 200 and g.width == 400 and g.height == 300
    end, 5), "drag client geometry did not settle")

    local g, s = c:geometry(), screen[1].geometry
    local done, status, err
    awful.spawn.easy_async({ POINTER, "drag",
        tostring(g.x + g.width / 2), tostring(g.y + g.height / 2),
        "900", "500", tostring(s.width), tostring(s.height), "300" },
        function(_, stderr, _, code) done, status, err = true, code, stderr end)
    local seen = false
    assert(async.wait_for_condition(function()
        if not seen and not done and mouse.coords().buttons[1]
            and awesome._clay_tree(screen[1]):find("drag.icon", 1, true) then
            seen = true
        end
        return done
    end, 5, 0.01), "virtual pointer drag timed out")
    assert(status == 0, "virtual pointer failed: " .. tostring(err))
    assert(seen, "no drag.icon element while the button was held")
    assert(async.wait_for_condition(function()
        return not mouse.coords().buttons[1]
            and not awesome._clay_tree(screen[1]):find("drag.icon", 1, true)
    end, 3, 0.01), "drag.icon remained after release")

    c:kill()
    assert(async.wait_for_no_clients(5), "drag client did not exit")
    runner.done()
end)
