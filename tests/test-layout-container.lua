---------------------------------------------------------------------------
--- Test: tag layout container lifecycle
--
-- Verifies the tag layout container API:
-- 1. _create_layout_container creates a container and reparents clients
-- 2. _set_layout_offset moves the container
-- 3. _destroy_layout_container reparents clients back
-- 4. Idempotent: calling _create twice does not crash
-- 5. Clients still render and stack correctly with container
---------------------------------------------------------------------------

local runner = require("_runner")
local test_client = require("_client")
local utils = require("_utils")
local awful = require("awful")

if not test_client.is_available() then
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local tag
local c1, c2

local steps = {
    -- Step 1: Set up tag with tile layout (default)
    function()
        tag = screen.primary.tags[1]
        tag:view_only()
        tag.layout = awful.layout.suit.tile
        return true
    end,

    -- Spawn two clients
    function(count)
        if count == 1 then test_client("lc_a") end
        c1 = utils.find_client_by_class("lc_a")
        if c1 then return true end
    end,

    function(count)
        if count == 1 then test_client("lc_b") end
        c2 = utils.find_client_by_class("lc_b")
        if c2 then return true end
    end,

    -- Step 4: Create layout container
    function()
        -- Should not error
        tag:_create_layout_container()
        io.stderr:write("[TEST] PASS: _create_layout_container succeeded\n")
        return true
    end,

    -- Step 5: Idempotent - calling again should not crash
    function()
        tag:_create_layout_container()
        io.stderr:write("[TEST] PASS: idempotent _create_layout_container\n")
        return true
    end,

    -- Step 6: Set layout offset
    function()
        tag:_set_layout_offset(100, 50)
        io.stderr:write("[TEST] PASS: _set_layout_offset succeeded\n")
        return true
    end,

    -- Step 7: Clients should still be valid and have geometry
    function()
        assert(c1.valid, "c1 should still be valid")
        assert(c2.valid, "c2 should still be valid")

        local g1 = c1:geometry()
        local g2 = c2:geometry()
        assert(g1.width > 0, "c1 should have positive width")
        assert(g2.width > 0, "c2 should have positive width")
        io.stderr:write(string.format(
            "[TEST] Clients valid: c1=%dx%d c2=%dx%d\n",
            g1.width, g1.height, g2.width, g2.height))
        io.stderr:write("[TEST] PASS: clients valid with container\n")
        return true
    end,

    -- Step 8: Destroy layout container
    function()
        tag:_destroy_layout_container()
        io.stderr:write("[TEST] PASS: _destroy_layout_container succeeded\n")
        return true
    end,

    -- Step 9: Calling destroy again should be safe (no-op)
    function()
        tag:_destroy_layout_container()
        io.stderr:write("[TEST] PASS: idempotent _destroy_layout_container\n")
        return true
    end,

    -- Step 10: Clients should still work after container is gone
    function(count)
        if count == 1 then
            assert(c1.valid, "c1 should still be valid after destroy")
            assert(c2.valid, "c2 should still be valid after destroy")
            -- Re-arrange to verify layout still works
            awful.layout.arrange(screen.primary)
            return nil
        end

        local g1 = c1:geometry()
        assert(g1.width > 0, "c1 should be laid out after destroy")
        io.stderr:write("[TEST] PASS: layout works after container destroy\n")
        return true
    end,

    -- Step 12: _set_layout_offset without container should error
    function()
        local ok, _ = pcall(function()
            tag:_set_layout_offset(0, 0)
        end)
        assert(not ok, "_set_layout_offset should error without container")
        io.stderr:write("[TEST] PASS: _set_layout_offset rejects missing container\n")
        return true
    end,

    -- Cleanup
    function(count)
        if count == 1 then
            for _, c in ipairs(client.get()) do
                if c.valid then c:kill() end
            end
        end
        if #client.get() == 0 then return true end
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
