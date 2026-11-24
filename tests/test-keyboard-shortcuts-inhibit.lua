---------------------------------------------------------------------------
--- A focused surface with a keyboard-shortcuts-inhibit-v1 inhibitor gets
--- Mod4 combos instead of the global key bindings. The bindings work again
--- once the surface is gone.
---------------------------------------------------------------------------
-- luacheck: globals awesome layer_surface

local runner = require("_runner")
local async = require("_async")
local awful = require("awful")
local utils = require("_utils")

local LAYER = utils.binary_or_skip("./build-test/test-layer-client")
if not LAYER then return runner.skip("test helper not built") end
local KEYBOARD = utils.binary_or_skip("./build-test/test-virtual-keyboard-client")
if not KEYBOARD then return runner.skip("test helper not built") end

runner.run_async(function()
    local presses = 0
    local key = awful.key({ "Mod4" }, "F9", function() presses = presses + 1 end)
    awful.keyboard.append_global_keybindings({ key })

    -- Returns after the client exits. Its closing roundtrip means the
    -- compositor has run keybinding() for every event it sent.
    local function press()
        local result
        awful.spawn.easy_async({ KEYBOARD, "Mod4", "F9" }, function(_, stderr, _, code)
            result = { code = code, stderr = stderr }
        end)
        assert(async.wait_for_condition(function() return result end, 5, 0.01),
            "virtual keyboard client did not exit")
        assert(result.code == 0, "virtual keyboard client failed: " .. result.stderr)
    end

    press()
    assert(async.wait_for_condition(function() return presses == 1 end, 5, 0.01),
        "Mod4+F9 from the virtual keyboard did not reach the global binding")

    local namespace = "shortcuts_inhibit"
    local pid = awful.spawn({ LAYER, "--namespace", namespace,
        "--keyboard", "exclusive", "--inhibit-shortcuts" })
    assert(type(pid) == "number", "spawn failed: " .. tostring(pid))
    local surface
    assert(async.wait_for_condition(function()
        for _, ls in ipairs(layer_surface.get()) do
            if ls.namespace == namespace then surface = ls end
        end
        return surface and surface.has_keyboard_focus
    end, 5, 0.01), "inhibiting layer surface did not receive keyboard focus")
    press()

    awesome.kill(pid, 15)
    assert(async.wait_for_condition(function() return not surface.valid end, 5, 0.01),
        "layer client did not exit")
    press()
    assert(async.wait_for_condition(function() return presses >= 2 end, 5, 0.01),
        "Mod4+F9 did not reach the global binding after the inhibitor was gone")
    assert(presses == 2, "expected 2 binding presses, got " .. presses
        .. ": the inhibited surface did not stop Mod4+F9")

    awful.keyboard.remove_global_keybinding(key)
    runner.done()
end)
