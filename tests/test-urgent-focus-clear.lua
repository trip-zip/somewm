---------------------------------------------------------------------------
--- Test: urgency is ignored for focused clients and cleared on focus gain
--
-- Verifies that:
-- 1. request::urgent on a focused client does not set urgency
-- 2. Urgency set on an unfocused client is cleared when it gains focus
---------------------------------------------------------------------------

local runner = require("_runner")
local async = require("_async")
local test_client = require("_client")

if not test_client.is_available() then
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

runner.run_async(function()
    -- Spawn client A (will be in master, gets focus)
    test_client("urgent_a")
    local a = async.wait_for_client("urgent_a", 5)
    assert(a, "Client A did not appear")

    local focused = async.wait_for_focus("urgent_a", 2)
    assert(focused, "Client A should have focus")
    assert(not a.urgent, "Focused client should not be urgent")

    -- Emit request::urgent on focused client - should be ignored by permissions
    a:emit_signal("request::urgent", true)
    async.sleep(0.1)
    assert(not a.urgent, "request::urgent should be ignored for focused client")

    -- Spawn client B (gets focus as new client)
    test_client("urgent_b")
    local b = async.wait_for_client("urgent_b", 5)
    assert(b, "Client B did not appear")

    local focused_b = async.wait_for_focus("urgent_b", 2)
    assert(focused_b, "Client B should have focus")

    -- Make A urgent while B has focus (A is unfocused, so this should stick)
    a:emit_signal("request::urgent", true)
    async.sleep(0.1)
    assert(a.urgent, "Unfocused client A should be urgent")

    -- Focus A - urgency should clear
    a:emit_signal("request::activate", "test", { raise = true })
    local focused_a = async.wait_for_focus("urgent_a", 2)
    assert(focused_a, "Client A should have focus")
    assert(not a.urgent, "Urgent state should be cleared on focus")

    -- Cleanup
    a:kill()
    b:kill()

    local gone = async.wait_for_no_clients(5)
    if not gone then
        for _, remaining in ipairs(client.get()) do
            if remaining.pid then
                os.execute("kill -9 " .. remaining.pid .. " 2>/dev/null")
            end
        end
        async.sleep(0.5)
        gone = async.wait_for_no_clients(2)
        assert(gone, "Clients did not close")
    end

    runner.done()
end)
