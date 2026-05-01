---------------------------------------------------------------------------
--- Test: layer-shell exclusive_zone positioning per protocol semantics
--
-- Verifies the three exclusive_zone modes from the wlr-layer-shell-v1 spec:
--
--   * exclusive_zone > 0: surface lays out in the *usable* area (after
--     other exclusives have been subtracted) AND reserves its own zone.
--   * exclusive_zone == 0: surface lays out in the *usable* area but
--     does NOT reserve any zone (typical for notifications, popups).
--   * exclusive_zone == -1: surface ignores other exclusives and extends
--     to its anchored edges (lays out in the full monitor area).
--
-- Regression: prior to the fix, all three cases used the full monitor
-- area for layout, which meant a notification (ezone=0) anchored to top
-- would overlap a waybar (ezone=50) anchored to the same edge.
---------------------------------------------------------------------------

local runner = require("_runner")
local async  = require("_async")
local awful  = require("awful")

local TEST_LAYER_CLIENT = "./build-test/test-layer-client"

local function file_exists(path)
    local f = io.open(path, "r")
    if not f then return false end
    f:close()
    return true
end

if not file_exists(TEST_LAYER_CLIENT) then
    io.stderr:write("SKIP: test-layer-client not found (run meson compile first)\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

-- Spawn a top-anchored layer client. Returns the spawned pid.
local function spawn_layer(namespace, exclusive_zone)
    local cmd = string.format(
        "%s --namespace %s --keyboard none --anchor top --exclusive-zone %d",
        TEST_LAYER_CLIENT, namespace, exclusive_zone)
    io.stderr:write("[TEST] Spawning: " .. cmd .. "\n")
    local pid = awful.spawn(cmd)
    assert(type(pid) == "number", "awful.spawn returned: " .. tostring(pid))
    return pid
end

-- Wait until a layer surface with the given namespace is mapped, then
-- return the layer_surface object.
local function wait_for_mapped(namespace, timeout)
    local found
    local ok = async.wait_for_condition(function()
        if not layer_surface then return false end
        for _, ls in ipairs(layer_surface.get()) do
            if ls.namespace == namespace and ls.mapped then
                found = ls
                return true
            end
        end
        return false
    end, timeout or 5)
    return ok and found or nil
end

local pids = {}

local function kill_all()
    for _, pid in ipairs(pids) do
        os.execute("kill -9 " .. pid .. " 2>/dev/null")
    end
end

runner.run_async(function()
    local screen = mouse.screen
    local sgeo = screen.geometry
    io.stderr:write(string.format("[TEST] Screen geometry: (%d, %d) %dx%d\n",
        sgeo.x, sgeo.y, sgeo.width, sgeo.height))

    -- 1. Spawn surface A: exclusive_zone=50, anchored top.
    --    Expect: A is positioned at y=screen.y (top of full_area, which
    --    is also top of initial usable_area). After A, usable_area.y
    --    moves down by 50.
    pids[#pids+1] = spawn_layer("test-ezone-A", 50)
    local a = wait_for_mapped("test-ezone-A", 5)
    assert(a, "surface A did not map within 5s")
    io.stderr:write(string.format("[TEST] A geometry: (%d, %d) %dx%d ezone=%d\n",
        a.geometry.x, a.geometry.y, a.geometry.width, a.geometry.height,
        a.exclusive_zone))
    assert(a.geometry.y == sgeo.y, string.format(
        "surface A (ezone=50) should be at top of screen (y=%d), got y=%d",
        sgeo.y, a.geometry.y))

    -- 2. Spawn surface B: exclusive_zone=0, anchored top.
    --    Expect (post-fix): B lays out in usable_area (which has been
    --    reduced by A's 50px exclusive zone). So B.y == sgeo.y + 50.
    --    Pre-fix: B would land at sgeo.y (overlapping A).
    pids[#pids+1] = spawn_layer("test-ezone-B", 0)
    local b = wait_for_mapped("test-ezone-B", 5)
    assert(b, "surface B did not map within 5s")
    io.stderr:write(string.format("[TEST] B geometry: (%d, %d) %dx%d ezone=%d\n",
        b.geometry.x, b.geometry.y, b.geometry.width, b.geometry.height,
        b.exclusive_zone))
    assert(b.geometry.y == sgeo.y + 50, string.format(
        "surface B (ezone=0) should respect A's exclusive zone " ..
        "(expected y=%d, got y=%d). This is the regression the fix targets.",
        sgeo.y + 50, b.geometry.y))

    -- 3. Spawn surface C: exclusive_zone=-1, anchored top.
    --    Expect: C ignores A's exclusive zone and lays out in full_area,
    --    so C.y == sgeo.y. Both pre-fix and post-fix agree on this case
    --    (pre-fix was correct by accident).
    pids[#pids+1] = spawn_layer("test-ezone-C", -1)
    local c = wait_for_mapped("test-ezone-C", 5)
    assert(c, "surface C did not map within 5s")
    io.stderr:write(string.format("[TEST] C geometry: (%d, %d) %dx%d ezone=%d\n",
        c.geometry.x, c.geometry.y, c.geometry.width, c.geometry.height,
        c.exclusive_zone))
    assert(c.geometry.y == sgeo.y, string.format(
        "surface C (ezone=-1) should ignore exclusives and stay at top " ..
        "(expected y=%d, got y=%d).",
        sgeo.y, c.geometry.y))

    io.stderr:write("[TEST] PASS: all three exclusive_zone modes correct\n")
    kill_all()
    runner.done()
end)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
