---------------------------------------------------------------------------
--- A button release over a layer surface fired the root release bindings,
--- although the matching press never reached the root bindings.
---------------------------------------------------------------------------

local runner = require("_runner")
local async = require("_async")
local awful = require("awful")
local gears = require("gears")
local utils = require("_utils")

local CLIENT = utils.binary_or_skip("./build-test/test-layer-client")
local POINTER = utils.binary_or_skip("./build-test/test-virtual-pointer-client")
if not CLIENT or not POINTER then return runner.skip("test helpers not built") end

local function click(x, y)
    local s = screen[1].geometry
    local done, status, err
    awful.spawn.easy_async({ POINTER, "click", tostring(x - s.x), tostring(y - s.y),
        tostring(s.width), tostring(s.height), "middle" }, function(_, stderr, _, code)
        done, status, err = true, code, stderr
    end)
    assert(async.wait_for_condition(function() return done end, 5, 0.01),
        "virtual pointer click timed out")
    assert(status == 0, "virtual pointer failed: " .. tostring(err))
end

runner.run_async(function()
    local presses, releases = 0, 0
    local original_buttons = root.buttons()
    root.buttons(gears.table.join(
        awful.button({}, 2, function() presses = presses + 1 end,
            function() releases = releases + 1 end)))

    local s = screen[1].geometry
    local pid = awful.spawn({ CLIENT, "--namespace", "release_root", "--keyboard", "none",
        "--anchor", "bottom,right", "--size", "200,100" })
    local surface
    assert(async.wait_for_condition(function()
        for _, ls in ipairs(layer_surface.get()) do
            if ls.namespace == "release_root" then surface = ls end
        end
        return surface and surface.mapped
    end, 5, 0.01), "layer surface did not map")

    local g = surface.geometry
    click(s.x + g.x + g.width / 2, s.y + g.y + g.height / 2)
    -- A desktop click afterwards proves the layer click was processed.
    click(s.x + 100, s.y + 100)
    assert(async.wait_for_condition(function() return releases >= 1 end, 3, 0.01),
        "desktop click did not reach root buttons")
    assert(presses == 1, "root press bindings fired " .. presses .. " times, expected 1")
    assert(releases == 1, "release over a layer surface fired root bindings ("
        .. releases .. " root releases, expected 1)")

    awesome.kill(pid, 15)
    assert(async.wait_for_condition(function() return not surface.valid end, 5, 0.01),
        "layer client did not exit")
    root.buttons = original_buttons
    runner.done()
end)
