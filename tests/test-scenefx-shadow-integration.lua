---------------------------------------------------------------------------
-- Test: SceneFX shadow + corner_radius interaction
--
-- Verifies that shadow and corner_radius properties work together:
-- - Setting corner_radius on a client with shadow doesn't crash
-- - Shadow config and corner_radius can both be set on same client
-- - Changing corner_radius after shadow is already created works
-- - Disabling shadow while corner_radius is set doesn't crash
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
local test_class = "somewm_sfx_shadow_test"

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

    -- Step 3: Enable shadow with config table
    function()
        c.shadow = {
            radius = 10,
            offset_x = -5,
            offset_y = -5,
            opacity = 0.6,
        }
        local s = c.shadow
        assert(s ~= nil, "shadow should not be nil")
        assert(type(s) == "table", "shadow should be table")
        assert(s.radius == 10, "shadow radius should be 10")
        io.stderr:write("[PASS] Shadow enabled on client\n")
        return true
    end,

    -- Step 4: Set corner_radius while shadow is active
    function()
        c.corner_radius = 12
        assert(c.corner_radius == 12,
            "corner_radius should be 12, got " .. tostring(c.corner_radius))
        -- Verify shadow is still intact
        local s = c.shadow
        assert(s ~= nil and type(s) == "table",
            "Shadow should still be active after setting corner_radius")
        io.stderr:write("[PASS] corner_radius set while shadow active\n")
        return true
    end,

    -- Step 5: Change corner_radius multiple times (no crash)
    function()
        for _, r in ipairs({0, 5, 20, 0, 15}) do
            c.corner_radius = r
            assert(c.corner_radius == r,
                "corner_radius should be " .. r .. ", got " .. tostring(c.corner_radius))
        end
        io.stderr:write("[PASS] Multiple corner_radius changes OK\n")
        return true
    end,

    -- Step 6: Disable shadow while corner_radius is set
    function()
        c.corner_radius = 10
        c.shadow = false
        assert(c.shadow == false, "Shadow should be disabled")
        assert(c.corner_radius == 10,
            "corner_radius should persist after shadow disable")
        io.stderr:write("[PASS] Shadow disabled while corner_radius active\n")
        return true
    end,

    -- Step 7: Re-enable shadow after corner_radius is set
    function()
        c.shadow = true
        local s = c.shadow
        assert(s ~= nil, "Shadow should be re-enabled")
        assert(c.corner_radius == 10,
            "corner_radius should still be 10")
        io.stderr:write("[PASS] Shadow re-enabled with corner_radius\n")
        return true
    end,

    -- Step 8: Reset both
    function()
        c.corner_radius = 0
        c.shadow = false
        assert(c.corner_radius == 0)
        assert(c.shadow == false)
        io.stderr:write("[PASS] Both properties reset to defaults\n")
        return true
    end,

    -- Step 9: Clean up
    function()
        c:kill()
        return true
    end,

    -- Step 10: Verify cleanup
    function()
        if #client.get() > 0 then return end
        io.stderr:write("[PASS] All scenefx shadow integration tests passed\n")
        return true
    end,
}

runner.run_steps(steps)
