---------------------------------------------------------------------------
--- Test: a layer-shell exclusive zone shrinks screen.workarea, so tiled
--- clients avoid it.
--
-- This is the Wayland-native replacement for X11 `client:struts{}` edge
-- reservation: an external panel anchors a layer surface with a positive
-- exclusive_zone, compose_screen folds that zone into screen.workarea (via
-- clay_c.layer_exclusive), and tiled clients lay out inside the reduced area.
---------------------------------------------------------------------------

local runner = require("_runner")
local async  = require("_async")
local awful  = require("awful")

local TEST_LAYER_CLIENT = "./build-test/test-layer-client"
local ZONE = 60

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

local pids = {}
local function kill_all()
    for _, pid in ipairs(pids) do
        os.execute("kill -9 " .. pid .. " 2>/dev/null")
    end
end

local function wait_for_mapped(namespace, timeout)
    local found
    async.wait_for_condition(function()
        if not layer_surface then return false end
        for _, ls in ipairs(layer_surface.get()) do
            if ls.namespace == namespace and ls.mapped then found = ls; return true end
        end
        return false
    end, timeout or 5)
    return found
end

runner.run_async(function()
    local s = mouse.screen
    local wa0 = s.workarea
    io.stderr:write(string.format("[TEST] baseline workarea: %dx%d+%d+%d\n",
        wa0.width, wa0.height, wa0.x, wa0.y))

    -- An external panel reserves the top edge via layer-shell.
    local cmd = string.format(
        "%s --namespace ws-panel --keyboard none --anchor top --exclusive-zone %d",
        TEST_LAYER_CLIENT, ZONE)
    io.stderr:write("[TEST] spawning panel: " .. cmd .. "\n")
    pids[#pids+1] = awful.spawn(cmd)
    local panel = wait_for_mapped("ws-panel", 5)
    assert(panel, "panel layer surface did not map")

    -- The exclusive zone must reach the screen (arrangelayers persists it for
    -- compose_screen). This is the regression: it used to stay 0 because the
    -- persist was gated on globalconf.screens.tab, which somewm never sets.
    local et = ({_somewm_clay.layer_exclusive(s)})[1]
    io.stderr:write(string.format("[TEST] layer_exclusive top=%d\n", et))
    assert(et == ZONE, string.format(
        "layer-shell exclusive zone should reach the screen (expected top=%d, got %d)",
        ZONE, et))

    -- compose_screen insets the workarea by that zone. Drive an arrange and
    -- read it back.
    awful.layout.arrange(s)
    local ok = async.wait_for_condition(function()
        local wa = s.workarea
        return wa.y == wa0.y + ZONE and wa.height == wa0.height - ZONE
    end, 5)
    local wa = s.workarea
    io.stderr:write(string.format("[TEST] workarea: %dx%d+%d+%d (baseline %dx%d+%d+%d)\n",
        wa.width, wa.height, wa.x, wa.y, wa0.width, wa0.height, wa0.x, wa0.y))
    assert(ok, string.format(
        "workarea should shrink by the %dpx exclusive zone (expected y=%d h=%d, got y=%d h=%d)",
        ZONE, wa0.y + ZONE, wa0.height - ZONE, wa.y, wa.height))
    io.stderr:write("[TEST] PASS: exclusive zone reserved workarea\n")

    kill_all(); pids = {}
    runner.done()
end)
