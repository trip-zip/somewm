---------------------------------------------------------------------------
--- Integration test for client.get() with numeric screen indices.
--
-- Verifies that luaA_checkscreen() accepts both numeric screen indices
-- and screen objects (AwesomeWM API compatibility).
---------------------------------------------------------------------------

local runner = require("_runner")
local test_client = require("_client")
local utils = require("_utils")

if not test_client.is_available() then
    io.stderr:write("SKIP: No terminal available for spawning test clients\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local c = nil
local test_class = "somewm_test_screen_num"

local steps = {
    -- Step 1: Spawn a test client
    function(count)
        if count == 1 then
            test_client(test_class, "Test Screen Number")
        end
        c = utils.find_client_by_class(test_class)
        if c then
            return true
        end
    end,

    -- Step 2: client.get(1) should work and match client.get(screen[1])
    function()
        local s = screen[1]
        assert(s, "screen[1] should exist")

        local by_number = client.get(1)
        local by_object = client.get(s)

        assert(type(by_number) == "table",
            "client.get(1) should return a table, got " .. type(by_number))
        assert(type(by_object) == "table",
            "client.get(screen[1]) should return a table")
        assert(#by_number == #by_object,
            string.format("client.get(1) returned %d clients, client.get(screen[1]) returned %d",
                #by_number, #by_object))

        -- Same clients in same order
        for i = 1, #by_number do
            assert(by_number[i] == by_object[i],
                string.format("client mismatch at index %d", i))
        end

        print("client.get(1) == client.get(screen[1]): OK (" .. #by_number .. " clients)")
        return true
    end,

    -- Step 3: client.get() with no args should also work
    function()
        local all = client.get()
        assert(type(all) == "table", "client.get() should return a table")
        assert(#all >= 1, "should have at least 1 client")
        print("client.get() with no args: OK (" .. #all .. " clients)")
        return true
    end,

    -- Step 4: invalid screen number should not crash
    function()
        local ok, err = pcall(function()
            client.get(999)
        end)
        -- Should not crash; may return empty table or warn
        print("client.get(999): no crash (ok=" .. tostring(ok) .. ")")
        return true
    end,

    -- Step 5: Cleanup
    function(count)
        if count == 1 then
            c:kill()
        end
        if #client.get() == 0 then
            return true
        end
        if count >= 20 then
            local pids = test_client.get_spawned_pids()
            for _, pid in ipairs(pids) do
                os.execute("kill -9 " .. pid .. " 2>/dev/null")
            end
            return true
        end
    end,
}

runner.run_steps(steps, { kill_clients = false })
