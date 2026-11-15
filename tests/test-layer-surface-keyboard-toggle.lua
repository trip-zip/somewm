---------------------------------------------------------------------------
--- Dropping layer keyboard interactivity left has_keyboard_focus true.
--- The stale flag prevented a later keyboard grant.
---------------------------------------------------------------------------

local runner = require("_runner")
local async = require("_async")
local awful = require("awful")
local utils = require("_utils")

local CLIENT = utils.binary_or_skip("./build-test/test-layer-client")
if not CLIENT then return runner.skip("test helper not built") end

runner.run_async(function()
    local namespace = "keyboard_toggle"
    local pid = awful.spawn({ CLIENT, "--namespace", namespace, "--keyboard", "exclusive" })
    local surface
    assert(async.wait_for_condition(function()
        for _, ls in ipairs(layer_surface.get()) do
            if ls.namespace == namespace then surface = ls end
        end
        return surface and surface.has_keyboard_focus
    end, 5, 0.01), "layer surface did not receive initial keyboard focus")

    local signals = 0
    surface:connect_signal("property::has_keyboard_focus", function() signals = signals + 1 end)
    awesome.kill(pid, 10)
    assert(async.wait_for_condition(function()
        return surface.keyboard_interactive == "none"
    end, 5, 0.01), "client did not commit keyboard interactivity none")
    assert(async.wait_for_condition(function()
        return surface.has_keyboard_focus == false
    end, 2, 0.01), "has_keyboard_focus stayed true after interactivity became none")
    awesome.kill(pid, 12)
    assert(async.wait_for_condition(function()
        return surface.keyboard_interactive == "exclusive" and surface.has_keyboard_focus
    end, 5, 0.01), "keyboard focus was not granted again")
    assert(signals == 2, "expected two focus property signals, got " .. signals)

    awesome.kill(pid, 15)
    assert(async.wait_for_condition(function() return not surface.valid end, 5),
        "layer client did not exit")
    runner.done()
end)
