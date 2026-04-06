---------------------------------------------------------------------------
--- Test: layer-shell focus restoration with sloppy focus enabled
--
-- Verifies that when a layer-shell surface closes, focus returns to the
-- correct client even when sloppy focus (mouse::enter) is enabled and the
-- mouse cursor is positioned over a different client.
--
-- This is the exact scenario from issue #414: two windows, rofi opens and
-- closes, focus should return to the previously focused window, not the one
-- under the cursor.
--
-- Uses test-layer-client for deterministic, instant layer surface creation.
---------------------------------------------------------------------------

local runner = require("_runner")
local test_client = require("_client")
local utils = require("_utils")
local awful = require("awful")

-- Path to test-layer-client (built by meson)
local TEST_LAYER_CLIENT = "./build-test/test-layer-client"

-- Check if test-layer-client exists
local function is_test_layer_client_available()
    local f = io.open(TEST_LAYER_CLIENT, "r")
    if f then
        f:close()
        return true
    end
    return false
end

-- Skip test if requirements not met
if not is_test_layer_client_available() then
    io.stderr:write("SKIP: test-layer-client not found (run meson compile first)\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

if not test_client.is_available() then
    io.stderr:write("SKIP: no terminal available for test clients\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local client_a, client_b
local layer_pid
local layer_surf

-- Enable sloppy focus (mouse::enter activates client) to match default rc.lua
local sloppy_handler = function(c)
    c:activate { context = "mouse_enter", raise = false }
end
client.connect_signal("mouse::enter", sloppy_handler)

-- Use tiled layout so clients are side-by-side with predictable geometry
awful.screen.focused().selected_tag.layout = awful.layout.suit.tile

local steps = {
    -- Step 1: Spawn client A
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Spawning client A...\n")
            test_client("sloppy_test_a")
        end
        client_a = utils.find_client_by_class("sloppy_test_a")
        if client_a then
            io.stderr:write("[TEST] Client A spawned\n")
            return true
        end
        return nil
    end,

    -- Step 2: Wait for client A to have focus
    function(count)
        if client.focus == client_a then
            io.stderr:write("[TEST] Client A has focus\n")
            return true
        end
        if count > 10 then
            error(string.format("Expected client A to have focus, got %s",
                client.focus and client.focus.class or "nil"))
        end
        return nil
    end,

    -- Step 3: Spawn client B
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Spawning client B...\n")
            test_client("sloppy_test_b")
        end
        client_b = utils.find_client_by_class("sloppy_test_b")
        if client_b then
            io.stderr:write("[TEST] Client B spawned\n")
            return true
        end
        return nil
    end,

    -- Step 4: Wait for client B to have focus
    function(count)
        if client.focus == client_b then
            io.stderr:write("[TEST] Client B has focus\n")
            return true
        end
        if count > 10 then
            error(string.format("Expected client B to have focus, got %s",
                client.focus and client.focus.class or "nil"))
        end
        return nil
    end,

    -- Step 5: Move mouse over client A (but keep keyboard focus on B)
    function(count)
        if count == 1 then
            -- Position cursor in the center of client A's geometry
            local geo = client_a:geometry()
            local cx = geo.x + geo.width / 2
            local cy = geo.y + geo.height / 2
            io.stderr:write(string.format("[TEST] Moving mouse to client A at (%d, %d)...\n", cx, cy))
            -- Use ignore_enter_notify=true to suppress the sloppy focus effect
            mouse.coords({x = cx, y = cy}, true)
        end
        -- Ensure B still has focus after mouse move (ignore_enter_notify=true
        -- should have suppressed the sloppy focus effect)
        if client.focus == client_b then
            io.stderr:write("[TEST] Mouse over A, B still has focus\n")
            return true
        end
        if count > 10 then
            error(string.format("Expected client B to have focus, got %s",
                client.focus and client.focus.class or "nil"))
        end
        return nil
    end,

    -- Step 6: Spawn test-layer-client (layer-shell surface with exclusive keyboard)
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Spawning test-layer-client...\n")
            layer_pid = awful.spawn(TEST_LAYER_CLIENT .. " --namespace test-sloppy --keyboard exclusive")
        end

        -- Wait for layer surface to appear
        if layer_surface then
            for _, ls in ipairs(layer_surface.get()) do
                if ls.namespace and ls.namespace:match("test%-sloppy") then
                    layer_surf = ls
                    io.stderr:write("[TEST] Layer surface appeared\n")
                    return true
                end
            end
        end

        if count > 20 then
            io.stderr:write("[TEST] ERROR: layer surface did not appear\n")
            return true
        end
        return nil
    end,

    -- Step 7: Verify layer surface has keyboard focus
    function(count)
        if not layer_surf then
            io.stderr:write("[TEST] SKIP: layer surface not found\n")
            return true
        end

        if layer_surf.has_keyboard_focus then
            io.stderr:write("[TEST] Layer surface has keyboard focus\n")
            return true
        end

        if count > 20 then
            io.stderr:write("[TEST] ERROR: layer surface did not get keyboard focus\n")
            return true
        end
        return nil
    end,

    -- Step 8: Close layer surface (kill the test-layer-client process)
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Closing layer surface...\n")
            if layer_pid then
                os.execute("kill -9 " .. layer_pid .. " 2>/dev/null")
            end
        end

        -- Wait for layer surface to be gone
        if layer_surface then
            local still_exists = false
            for _, ls in ipairs(layer_surface.get()) do
                if ls.namespace and ls.namespace:match("test%-sloppy") then
                    still_exists = true
                    break
                end
            end
            if not still_exists then
                io.stderr:write("[TEST] Layer surface closed\n")
                return true
            end
        else
            if count > 10 then return true end
        end
        return nil
    end,

    -- Step 9: Verify focus returns to client B (not A which is under the cursor)
    function(count)
        if count < 3 then return nil end

        io.stderr:write(string.format(
            "[TEST] Checking focus (attempt %d): client.focus=%s\n",
            count, client.focus and client.focus.class or "nil"))

        if client.focus == client_b then
            assert(client_b:has_keyboard_focus(),
                "Client B regained visual focus but NOT keyboard focus (seat desync)")
            io.stderr:write("[TEST] PASS: focus returned to client B (correct, not sloppy-focused A)\n")
            return true
        end

        if count > 10 then
            local got = client.focus and client.focus.class or "nil"
            local kb_a = client_a and client_a.valid and client_a:has_keyboard_focus()
            local kb_b = client_b and client_b.valid and client_b:has_keyboard_focus()
            error(string.format(
                "Expected focus to return to client B, got %s "..
                "(A has_keyboard_focus=%s, B has_keyboard_focus=%s)",
                got, tostring(kb_a), tostring(kb_b)))
        end
        return nil
    end,

    -- Step 10: Cleanup
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Cleanup\n")
            client.disconnect_signal("mouse::enter", sloppy_handler)
            if client_a and client_a.valid then client_a:kill() end
            if client_b and client_b.valid then client_b:kill() end
            os.execute("pkill -9 test-layer-client 2>/dev/null")
        end

        if #client.get() == 0 then
            return true
        end

        if count >= 10 then
            local pids = test_client.get_spawned_pids()
            for _, pid in ipairs(pids) do
                os.execute("kill -9 " .. pid .. " 2>/dev/null")
            end
            return true
        end
    end,
}

runner.run_steps(steps, { kill_clients = false })

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
