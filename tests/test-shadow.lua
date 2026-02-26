---------------------------------------------------------------------------
-- Test: Shadow property API for clients and wiboxes
--
-- Verifies that the 9-slice drop shadow system works correctly:
-- - Shadow config roundtrips through Lua (set → get)
-- - Shadow can be enabled/disabled on wiboxes and clients
-- - Shadow works in the wibox constructor
-- - Per-object shadow overrides work
--
-- @author somewm contributors
-- @copyright 2026 somewm contributors
---------------------------------------------------------------------------

local runner = require("_runner")
local test_client = require("_client")
local utils = require("_utils")
local awful = require("awful")
local wibox = require("wibox")

-- Skip test if no terminal available (needed for client shadow tests)
if not test_client.is_available() then
    io.stderr:write("SKIP: No terminal available for spawning test clients\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local test_wibox_1 = nil
local test_wibox_2 = nil
local c = nil
local test_class = "somewm_shadow_test"

local steps = {
    -- Step 1: Create wibox and set shadow via post-creation assignment
    function()
        test_wibox_1 = wibox {
            x = 50,
            y = 50,
            width = 200,
            height = 100,
            bg = "#ff5500",
            visible = true,
            screen = awful.screen.focused(),
        }
        test_wibox_1.shadow = {
            radius = 15,
            offset_x = 2,
            offset_y = 8,
            opacity = 0.7,
            clip_directional = true,
        }
        io.stderr:write("[TEST] Created wibox with shadow config\n")
        return true
    end,

    -- Step 2: Verify shadow config roundtrips correctly
    function()
        local s = test_wibox_1.shadow
        assert(s ~= nil, "shadow should not be nil")
        assert(type(s) == "table", "shadow should be a table, got " .. type(s))
        assert(s.enabled == true, "shadow should be enabled")
        assert(s.radius == 15, "radius should be 15, got " .. tostring(s.radius))
        assert(s.offset_x == 2, "offset_x should be 2, got " .. tostring(s.offset_x))
        assert(s.offset_y == 8, "offset_y should be 8, got " .. tostring(s.offset_y))
        assert(s.clip_directional == true, "clip_directional should be true")
        -- opacity is float, check approximate
        assert(s.opacity > 0.69 and s.opacity < 0.71,
            "opacity should be ~0.7, got " .. tostring(s.opacity))
        io.stderr:write("[PASS] Shadow config roundtrip verified\n")
        return true
    end,

    -- Step 3: Disable shadow
    function()
        test_wibox_1.shadow = false
        local s = test_wibox_1.shadow
        assert(s == false, "shadow should be false after disabling, got " .. tostring(s))
        io.stderr:write("[PASS] Shadow disable verified\n")
        return true
    end,

    -- Step 4: Re-enable shadow with boolean true (use defaults)
    -- D1: Verify documented default values (-15/-15/0.75)
    -- D3: Verify getter returns table (not boolean) when enabled
    function()
        test_wibox_1.shadow = true
        local s = test_wibox_1.shadow
        assert(s ~= nil and s ~= false,
            "shadow should be truthy after enabling, got " .. tostring(s))
        assert(type(s) == "table",
            "shadow getter should return table, got " .. type(s))
        assert(s.enabled == true, "shadow should be enabled")
        assert(s.radius == 12,
            "default radius should be 12, got " .. tostring(s.radius))
        assert(s.offset_x == -15,
            "default offset_x should be -15, got " .. tostring(s.offset_x))
        assert(s.offset_y == -15,
            "default offset_y should be -15, got " .. tostring(s.offset_y))
        assert(s.opacity > 0.74 and s.opacity < 0.76,
            "default opacity should be ~0.75, got " .. tostring(s.opacity))
        io.stderr:write("[PASS] Shadow re-enable with defaults verified (D1/D3)\n")
        return true
    end,

    -- Step 5: Create wibox with shadow in constructor args
    function()
        test_wibox_2 = wibox {
            x = 300,
            y = 50,
            width = 200,
            height = 100,
            bg = "#0055ff",
            visible = true,
            screen = awful.screen.focused(),
            shadow = true,
        }
        local s = test_wibox_2.shadow
        assert(s ~= nil and s ~= false,
            "constructor shadow should be truthy, got " .. tostring(s))
        io.stderr:write("[PASS] Shadow in wibox constructor verified\n")
        return true
    end,

    -- Step 6: Spawn a client for client shadow tests
    function(count)
        if count == 1 then
            test_client(test_class, "Shadow Test Window")
        end
        c = utils.find_client_by_class(test_class)
        if c then
            io.stderr:write("[TEST] Test client spawned\n")
            return true
        end
    end,

    -- Step 7: Set per-client shadow override
    function()
        c.shadow = {
            radius = 20,
            offset_x = 0,
            offset_y = 10,
            opacity = 0.5,
        }
        local s = c.shadow
        assert(s ~= nil, "client shadow should not be nil")
        assert(type(s) == "table", "client shadow should be a table")
        assert(s.radius == 20, "client radius should be 20, got " .. tostring(s.radius))
        assert(s.offset_y == 10, "client offset_y should be 10, got " .. tostring(s.offset_y))
        io.stderr:write("[PASS] Client shadow override verified\n")
        return true
    end,

    -- Step 8: Partial table override inherits defaults for unspecified values (D4)
    function()
        c.shadow = { offset_x = 5 }
        local s = c.shadow
        assert(type(s) == "table", "partial override should return table")
        assert(s.enabled == true, "partial override should be enabled")
        assert(s.offset_x == 5,
            "offset_x should be overridden to 5, got " .. tostring(s.offset_x))
        -- Unspecified values should come from defaults, not be zero/hardcoded
        assert(s.radius == 12,
            "unspecified radius should be default 12, got " .. tostring(s.radius))
        assert(s.offset_y == -15,
            "unspecified offset_y should be default -15, got " .. tostring(s.offset_y))
        assert(s.opacity > 0.74 and s.opacity < 0.76,
            "unspecified opacity should be default ~0.75, got " .. tostring(s.opacity))
        io.stderr:write("[PASS] Partial table override uses defaults (D4)\n")
        return true
    end,

    -- Step 9: Disable client shadow
    function()
        c.shadow = false
        local s = c.shadow
        assert(s == false, "client shadow should be false, got " .. tostring(s))
        io.stderr:write("[PASS] Client shadow disable verified\n")
        return true
    end,

    -- Step 10: Cleanup
    function(count)
        if count == 1 then
            if test_wibox_1 then
                test_wibox_1.visible = false
                test_wibox_1 = nil
            end
            if test_wibox_2 then
                test_wibox_2.visible = false
                test_wibox_2 = nil
            end
            if c then
                c:kill()
            end
        end

        local clients = client.get()
        if #clients == 0 then
            io.stderr:write("[TEST] Cleanup complete\n")
            return true
        end
        if count >= 20 then
            io.stderr:write("[TEST] Forcing cleanup\n")
            return true
        end
    end,
}

runner.run_steps(steps, { kill_clients = false })

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
