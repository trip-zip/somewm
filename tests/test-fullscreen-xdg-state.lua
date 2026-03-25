---------------------------------------------------------------------------
--- Test: xdg-shell fullscreen state matches Lua fullscreen property
--
-- When Lua sets c.fullscreen = true, the xdg-shell protocol must also
-- tell the client it is fullscreen (via wlr_xdg_toplevel_set_fullscreen).
-- The c.xdg_fullscreen property reads the protocol-level state so we can
-- verify the two stay in sync.
---------------------------------------------------------------------------

local runner = require("_runner")
local test_client = require("_client")
local utils = require("_utils")

if not test_client.is_available() then
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local my_client

local steps = {
    -- Step 1: Spawn a client
    function(count)
        if count == 1 then
            test_client("xdg_fs_test")
        end
        my_client = utils.find_client_by_class("xdg_fs_test")
        if not my_client then return nil end
        io.stderr:write("[TEST] Client spawned\n")
        return true
    end,

    -- Step 2: Verify initial state - neither Lua nor xdg should be fullscreen
    function(count)
        if count < 3 then return nil end

        assert(not my_client.fullscreen,
            "Client should not be fullscreen initially")
        assert(not my_client.xdg_fullscreen,
            "xdg_fullscreen should be false initially")

        io.stderr:write("[TEST] PASS: initial state correct\n")
        return true
    end,

    -- Step 3: Set fullscreen via Lua and verify xdg state follows
    function(count)
        if count == 1 then
            my_client.fullscreen = true
        end
        if count < 3 then return nil end

        assert(my_client.fullscreen,
            "c.fullscreen should be true after setting it")
        assert(my_client.xdg_fullscreen,
            "c.xdg_fullscreen should be true after c.fullscreen = true")

        io.stderr:write("[TEST] PASS: xdg_fullscreen follows fullscreen = true\n")
        return true
    end,

    -- Step 4: Unset fullscreen and verify xdg state follows
    function(count)
        if count == 1 then
            my_client.fullscreen = false
        end
        if count < 3 then return nil end

        assert(not my_client.fullscreen,
            "c.fullscreen should be false after unsetting")
        assert(not my_client.xdg_fullscreen,
            "c.xdg_fullscreen should be false after c.fullscreen = false")

        io.stderr:write("[TEST] PASS: xdg_fullscreen follows fullscreen = false\n")
        return true
    end,

    -- Cleanup
    function(count)
        if count == 1 then
            if my_client and my_client.valid then my_client:kill() end
        end
        if #client.get() == 0 then return true end
        if count > 15 then return true end
        return nil
    end,
}

runner.run_steps(steps, { kill_clients = false })
