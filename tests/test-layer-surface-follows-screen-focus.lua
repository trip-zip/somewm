-- A layer surface that names no output opens on the screen awful.screen.focus
-- moved to. The pointer warp from mouse.coords does not run motionnotify(), so
-- the selected monitor must follow the warp itself. Needs two outputs (the
-- two-output lane in tests/README.md).

local awful  = require("awful")
local runner = require("_runner")
local utils  = require("_utils")

if screen.count() < 2 then
    return runner.skip("test-layer-surface-follows-screen-focus requires WLR_HEADLESS_OUTPUTS=2")
end

local LAYER_CLIENT = utils.binary_or_skip("./build-test/test-layer-client")
if not LAYER_CLIENT then return end

local NAMESPACE = "test-follows-screen-focus"
local s1, s2 = screen[1], screen[2]
local pid

local function find_surface()
    for _, ls in ipairs(layer_surface.get()) do
        if ls.namespace == NAMESPACE then return ls end
    end
end

runner.run_steps({
    function()
        local g = s1.geometry
        root.fake_input("motion_notify", false, g.x + g.width / 2, g.y + g.height / 2)
        return mouse.screen == s1 or nil
    end,
    function()
        awful.screen.focus(s2)
        assert(mouse.screen == s2, "awful.screen.focus did not move the pointer")
        pid = awful.spawn(LAYER_CLIENT .. " --namespace " .. NAMESPACE .. " --keyboard none")
        return true
    end,
    function()
        local ls = find_surface()
        if not ls or not ls.screen then return nil end
        assert(ls.screen == s2, string.format(
            "layer surface opened on screen %d, focus is on screen %d",
            ls.screen.index, s2.index))
        awesome.kill(pid, 9)
        return true
    end,
    function()
        local ls = find_surface()
        return (not ls or not ls.valid) or nil
    end,
}, { kill_clients = false })
