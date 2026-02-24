---------------------------------------------------------------------------
--- Test: minimized clients stay minimized after tag switch
--
-- Regression test for #217: minimized clients reappear when switching
-- tags away and back. The fix replaces client_on_selected_tags() with
-- client_isvisible() in arrange() so minimized/hidden state is respected.
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

local c1
local tag1, tag2

local steps = {
    -- Step 1: Create a second tag, select tag1, spawn a client
    function(count)
        if count == 1 then
            tag1 = screen.primary.tags[1]
            tag2 = awful.tag.add("test2", { screen = screen.primary })
            assert(tag1 and tag2, "Failed to set up tags")
            tag1:view_only()
            io.stderr:write("[TEST] Spawning client on tag1...\n")
            test_client("min_test")
        end
        c1 = utils.find_client_by_class("min_test")
        if c1 then
            io.stderr:write("[TEST] Client spawned\n")
            return true
        end
        return nil
    end,

    -- Step 2: Minimize the client
    function()
        assert(not c1.minimized, "Client should start unminimized")
        assert(c1:isvisible(), "Client should be visible")
        io.stderr:write("[TEST] Minimizing client...\n")
        c1.minimized = true
        assert(c1.minimized, "Client should be minimized")
        assert(not c1:isvisible(), "Minimized client should not be visible")
        return true
    end,

    -- Step 3: Switch to tag2
    function()
        io.stderr:write("[TEST] Switching to tag2...\n")
        tag2:view_only()
        return true
    end,

    -- Step 4: Switch back to tag1
    function()
        io.stderr:write("[TEST] Switching back to tag1...\n")
        tag1:view_only()
        return true
    end,

    -- Step 5: Verify client is still minimized
    function()
        assert(c1.valid, "Client should still be valid")
        assert(c1.minimized,
            "Client should still be minimized after tag switch")
        assert(not c1:isvisible(),
            "BUG #217: Minimized client became visible after tag switch!")
        io.stderr:write("[TEST] PASS: client stayed minimized after tag switch\n")
        return true
    end,

    -- Step 6: Cleanup
    function(count)
        if count == 1 then
            io.stderr:write("[TEST] Cleanup: killing client\n")
            if c1 and c1.valid then
                c1:kill()
            end
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
        return nil
    end,
}

runner.run_steps(steps, { kill_clients = false })
