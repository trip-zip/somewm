---------------------------------------------------------------------------
-- Test: SceneFX backdrop_blur property on clients
--
-- Verifies the backdrop_blur Lua API works correctly:
-- - Property defaults to false
-- - Setting/getting roundtrips correctly
-- - Emits property::backdrop_blur signal
-- - Works alongside opacity and corner_radius
-- - Works without scenefx (stores value, no visual effect)
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
local test_class = "somewm_blur_test"

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

    -- Step 3: Verify default backdrop_blur is false
    function()
        assert(c.backdrop_blur == false,
            "Default backdrop_blur should be false, got " .. tostring(c.backdrop_blur))
        io.stderr:write("[PASS] Default backdrop_blur is false\n")
        return true
    end,

    -- Step 4: Enable backdrop_blur
    function()
        c.backdrop_blur = true
        assert(c.backdrop_blur == true,
            "backdrop_blur should be true, got " .. tostring(c.backdrop_blur))
        io.stderr:write("[PASS] backdrop_blur enabled\n")
        return true
    end,

    -- Step 5: Disable backdrop_blur
    function()
        c.backdrop_blur = false
        assert(c.backdrop_blur == false,
            "backdrop_blur should be false, got " .. tostring(c.backdrop_blur))
        io.stderr:write("[PASS] backdrop_blur disabled\n")
        return true
    end,

    -- Step 6: Verify property::backdrop_blur signal fires
    function()
        signal_fired = false
        c:connect_signal("property::backdrop_blur", function()
            signal_fired = true
        end)
        c.backdrop_blur = true
        assert(signal_fired, "property::backdrop_blur signal should fire")
        io.stderr:write("[PASS] property::backdrop_blur signal fires\n")
        return true
    end,

    -- Step 7: Combine with corner_radius and opacity
    function()
        c.corner_radius = 12
        c.opacity = 0.8
        c.backdrop_blur = true
        assert(c.corner_radius == 12, "corner_radius should be 12")
        assert(c.backdrop_blur == true, "backdrop_blur should be true")
        -- opacity is float, check approximate
        assert(c.opacity > 0.79 and c.opacity < 0.81,
            "opacity should be ~0.8, got " .. tostring(c.opacity))
        io.stderr:write("[PASS] backdrop_blur + corner_radius + opacity combined\n")
        return true
    end,

    -- Step 8: Toggle blur multiple times (no crash)
    function()
        for i = 1, 10 do
            c.backdrop_blur = (i % 2 == 0)
        end
        assert(c.backdrop_blur == true, "After 10 toggles, should be true")
        io.stderr:write("[PASS] Multiple blur toggles OK\n")
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
        io.stderr:write("[PASS] All scenefx backdrop_blur tests passed\n")
        return true
    end,
}

runner.run_steps(steps)
