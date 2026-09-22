---------------------------------------------------------------------------
--- Test: `client close` and `client kill` reach the client's kill method.
--
-- ipc called kill on the client class, where the C binding registers it as
-- a method, so both commands failed for every target.
---------------------------------------------------------------------------

local runner = require("_runner")
local async = require("_async")
local test_client = require("_client")
local ipc = require("awful.ipc")

if not test_client.is_available() then
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

runner.run_async(function()
    test_client("ipc_close")
    local c = async.wait_for_client("ipc_close", 5)
    assert(c, "Client did not appear")
    client.focus = c
    assert(async.wait_for_focus("ipc_close", 2), "Client should have focus")

    for _, command in ipairs { "client close focused", "client kill " .. c.id } do
        local response = ipc.dispatch(command)
        assert(response:match("^OK\n"), command .. " answered: " .. response)
    end

    runner.done()
end)
