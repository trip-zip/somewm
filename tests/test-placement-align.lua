---------------------------------------------------------------------------
--- Test: Phase 9 awful.placement.align via Clay-backed somewm.placement.
---
--- Smoke tests against a real client to confirm the Clay fast path produces
--- the same geometry as the legacy align_map and that args dict semantics
--- (honor_workarea, parent override) flow through correctly. Geometry is
--- actually applied (not just returned) - the legacy path's full pipeline
--- (remove_border, geometry_common, attach, fix_new_geometry) still runs.
---
--- Run: make test-one TEST=tests/test-placement-align.lua
---------------------------------------------------------------------------

local runner = require("_runner")
local async  = require("_async")
local test_client = require("_client")
local awful  = require("awful")

if not test_client.is_available() then
    io.stderr:write("SKIP: no terminal available\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local function cleanup(c_to_kill)
    if c_to_kill and c_to_kill.valid then
        c_to_kill:kill()
    end
    for _, pid in ipairs(test_client.get_spawned_pids()) do
        os.execute("kill -9 " .. pid .. " 2>/dev/null")
    end
    return async.wait_for_no_clients(5)
end

runner.run_async(function()

    -- TEST 1: centered on screen workarea, no border.
    io.stderr:write("[TEST 1] awful.placement.centered, honor_workarea\n")
    test_client("place_align_1")
    local c = async.wait_for_client("place_align_1", 5)
    assert(c, "Client did not appear")
    c.floating = true
    c.border_width = 0
    c:geometry({ x = 0, y = 0, width = 400, height = 300 })
    async.sleep(0.1)

    awful.placement.centered(c, { honor_workarea = true })
    async.sleep(0.1)

    local sgeo = c.screen.workarea
    local geo = c:geometry()
    local exp_x = sgeo.x + math.ceil((sgeo.width  - 400) / 2)
    local exp_y = sgeo.y + math.ceil((sgeo.height - 300) / 2)
    assert(geo.x == exp_x,
        string.format("[TEST 1] x: expected %d, got %d", exp_x, geo.x))
    assert(geo.y == exp_y,
        string.format("[TEST 1] y: expected %d, got %d", exp_y, geo.y))
    assert(geo.width == 400 and geo.height == 300,
        string.format("[TEST 1] size mismatch: %dx%d", geo.width, geo.height))
    io.stderr:write("[TEST 1] PASS\n")

    assert(cleanup(c), "Cleanup 1: client did not close")

    -- TEST 2: top_left on full screen geometry (NOT workarea).
    io.stderr:write("[TEST 2] awful.placement.top_left, no honor_workarea\n")
    test_client("place_align_2")
    local c2 = async.wait_for_client("place_align_2", 5)
    assert(c2, "Client 2 did not appear")
    c2.floating = true
    c2.border_width = 0
    c2:geometry({ x = 100, y = 100, width = 200, height = 150 })
    async.sleep(0.1)

    awful.placement.top_left(c2)
    async.sleep(0.1)

    local sgeo2 = c2.screen.geometry
    local geo2 = c2:geometry()
    assert(geo2.x == sgeo2.x,
        string.format("[TEST 2] x: expected %d, got %d", sgeo2.x, geo2.x))
    assert(geo2.y == sgeo2.y,
        string.format("[TEST 2] y: expected %d, got %d", sgeo2.y, geo2.y))
    io.stderr:write("[TEST 2] PASS\n")

    assert(cleanup(c2), "Cleanup 2: client did not close")

    -- TEST 3: bottom_right pushes to far corner.
    io.stderr:write("[TEST 3] awful.placement.bottom_right, honor_workarea\n")
    test_client("place_align_3")
    local c3 = async.wait_for_client("place_align_3", 5)
    assert(c3, "Client 3 did not appear")
    c3.floating = true
    c3.border_width = 0
    c3:geometry({ x = 0, y = 0, width = 250, height = 200 })
    async.sleep(0.1)

    awful.placement.bottom_right(c3, { honor_workarea = true })
    async.sleep(0.1)

    local sgeo3 = c3.screen.workarea
    local geo3 = c3:geometry()
    local exp_x3 = sgeo3.x + sgeo3.width  - 250
    local exp_y3 = sgeo3.y + sgeo3.height - 200
    assert(geo3.x == exp_x3,
        string.format("[TEST 3] x: expected %d, got %d", exp_x3, geo3.x))
    assert(geo3.y == exp_y3,
        string.format("[TEST 3] y: expected %d, got %d", exp_y3, geo3.y))
    io.stderr:write("[TEST 3] PASS\n")

    assert(cleanup(c3), "Cleanup 3: client did not close")

    io.stderr:write("[ALL TESTS] PASS\n")
    runner.done()
end)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
