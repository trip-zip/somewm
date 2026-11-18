---------------------------------------------------------------------------
--- Scrolling over a layer surface, e.g. lan-mouse's capture surface, fired
--- the root scroll bindings.
---------------------------------------------------------------------------

local runner = require("_runner")
local async = require("_async")
local awful = require("awful")
local gears = require("gears")
local utils = require("_utils")

local CLIENT = utils.binary_or_skip("./build-test/test-layer-client")
local POINTER = utils.binary_or_skip("./build-test/test-virtual-pointer-client")
if not CLIENT or not POINTER then return runner.skip("test helpers not built") end

local function pointer(action, x, y, arg)
    local s = screen[1].geometry
    local done, status, err
    local cmd = { POINTER, action, tostring(x - s.x), tostring(y - s.y),
        tostring(s.width), tostring(s.height) }
    if arg then cmd[#cmd + 1] = arg end
    awful.spawn.easy_async(cmd, function(_, stderr, _, code)
        done, status, err = true, code, stderr
    end)
    assert(async.wait_for_condition(function() return done end, 5, 0.01),
        "virtual pointer " .. action .. " timed out")
    assert(status == 0, "virtual pointer failed: " .. tostring(err))
end

runner.run_async(function()
    local scrolls = 0
    local original_buttons = root.buttons()
    root.buttons(gears.table.join(
        awful.button({}, 4, function() scrolls = scrolls + 1 end),
        awful.button({}, 5, function() scrolls = scrolls + 1 end)))

    local s = screen[1].geometry
    local pid = awful.spawn({ CLIENT, "--namespace", "scroll_root", "--keyboard", "none",
        "--anchor", "bottom,right", "--size", "200,100" })
    local surface
    assert(async.wait_for_condition(function()
        for _, ls in ipairs(layer_surface.get()) do
            if ls.namespace == "scroll_root" then surface = ls end
        end
        return surface and surface.mapped
    end, 5, 0.01), "layer surface did not map")

    -- Control: a scroll over the empty desktop reaches the root bindings.
    pointer("scroll", s.x + 100, s.y + 100, "down")
    assert(async.wait_for_condition(function() return scrolls == 1 end, 3, 0.01),
        "scroll over the desktop must trigger root buttons")

    local g = surface.geometry
    local x, y = s.x + g.x + g.width / 2, s.y + g.y + g.height / 2
    pointer("scroll", x, y, "down")
    pointer("scroll", x, y, "up")
    -- A desktop scroll afterwards proves the layer scrolls were processed.
    pointer("scroll", s.x + 100, s.y + 100, "up")
    assert(async.wait_for_condition(function() return scrolls >= 2 end, 3, 0.01),
        "second desktop scroll did not arrive")
    assert(scrolls == 2, "scroll over a layer surface triggered root buttons ("
        .. scrolls .. " root scrolls, expected 2)")

    awesome.kill(pid, 15)
    assert(async.wait_for_condition(function() return not surface.valid end, 5, 0.01),
        "layer client did not exit")
    root.buttons = original_buttons
    runner.done()
end)
