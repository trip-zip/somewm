---------------------------------------------------------------------------
-- Test: SceneFX corner_radius property on clients
--
-- Verifies the corner_radius Lua API works correctly:
-- - Property defaults to 0
-- - Setting/getting roundtrips correctly
-- - Negative values are rejected
-- - Works without scenefx (stores value, no visual effect)
-- - Emits property::corner_radius signal
--
-- @author somewm contributors
-- @copyright 2026 somewm contributors
---------------------------------------------------------------------------

local runner = require("_runner")
local test_client = require("_client")
local awful = require("awful")

if not test_client.is_available() then
    io.stderr:write("SKIP: No terminal available for spawning test clients\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local c = nil
local signal_fired = false
local test_class = "somewm_corner_radius_test"

local steps = {
    -- Step 1: Spawn a test client
    function()
        test_client(test_class)
        return true
    end,

    -- Step 2: Wait for client
    function()
        c = nil
        for _, cl in ipairs(client.get()) do
            if cl.class == test_class then
                c = cl
                break
            end
        end
        if not c then return end
        io.stderr:write("[TEST] Got test client: " .. tostring(c.name) .. "\n")
        return true
    end,

    -- Step 3: Verify default corner_radius is 0
    function()
        assert(c.corner_radius == 0,
            "Default corner_radius should be 0, got " .. tostring(c.corner_radius))
        io.stderr:write("[PASS] Default corner_radius is 0\n")
        return true
    end,

    -- Step 4: Set corner_radius and verify roundtrip
    function()
        c.corner_radius = 12
        assert(c.corner_radius == 12,
            "corner_radius should be 12, got " .. tostring(c.corner_radius))
        io.stderr:write("[PASS] corner_radius roundtrip: 12\n")
        return true
    end,

    -- Step 5: Set corner_radius to 0 (sharp corners)
    function()
        c.corner_radius = 0
        assert(c.corner_radius == 0,
            "corner_radius should be 0, got " .. tostring(c.corner_radius))
        io.stderr:write("[PASS] corner_radius reset to 0\n")
        return true
    end,

    -- Step 6: Verify negative values are rejected
    function()
        local ok, err = pcall(function()
            c.corner_radius = -5
        end)
        assert(not ok, "Negative corner_radius should be rejected")
        assert(c.corner_radius == 0,
            "corner_radius should still be 0 after rejected set")
        io.stderr:write("[PASS] Negative corner_radius rejected\n")
        return true
    end,

    -- Step 7: Verify property::corner_radius signal fires
    function()
        signal_fired = false
        c:connect_signal("property::corner_radius", function()
            signal_fired = true
        end)
        c.corner_radius = 8
        assert(signal_fired, "property::corner_radius signal should fire")
        io.stderr:write("[PASS] property::corner_radius signal fires\n")
        return true
    end,

    -- Step 8: Verify large corner_radius is accepted
    function()
        c.corner_radius = 100
        assert(c.corner_radius == 100,
            "corner_radius should accept large values, got " .. tostring(c.corner_radius))
        io.stderr:write("[PASS] Large corner_radius accepted\n")
        return true
    end,

    -- Step 9: Clean up
    function()
        c:kill()
        return true
    end,

    -- Step 10: Wait for client to be gone
    function()
        if #client.get() > 0 then return end
        io.stderr:write("[PASS] All scenefx corner_radius tests passed\n")
        return true
    end,
}

runner.run_steps(steps)
