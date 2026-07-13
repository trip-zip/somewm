---------------------------------------------------------------------------
--- Test: closing a focused client emits "unfocus"
--
-- AwesomeWM emits "unfocus" (and property::active=false) from
-- client_unmanage(), before request::unmanage and while the client is
-- still valid. somewm used to clear globalconf.focus.client in
-- unmapnotify(), so client_unmanage() found no focused client and the
-- signal was never emitted.
---------------------------------------------------------------------------

local runner = require("_runner")
local async = require("_async")
local test_client = require("_client")

if not test_client.is_available() then
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local events = {}
local unfocused, valid_at_unfocus

client.connect_signal("unfocus", function(c)
    if c.class ~= "unfocus_close" then return end
    table.insert(events, "unfocus")
    unfocused = c
    valid_at_unfocus = c.valid
end)

client.connect_signal("property::active", function(c)
    if c.class ~= "unfocus_close" or c.active then return end
    table.insert(events, "property::active")
end)

client.connect_signal("request::unmanage", function(c)
    if c.class ~= "unfocus_close" then return end
    table.insert(events, "request::unmanage")
end)

runner.run_async(function()
    test_client("unfocus_close")
    local c = async.wait_for_client("unfocus_close", 5)
    assert(c, "Client did not appear")
    assert(async.wait_for_focus("unfocus_close", 2), "Client should have focus")

    -- kitty ignores the close request while its child (sleep infinity) runs,
    -- so kill the process to get a real surface destroy.
    assert(c.pid, "Client has no pid")
    os.execute("kill " .. c.pid)
    async.wait_for_condition(function() return #events >= 3 end, 10)

    assert(unfocused, "unfocus was not emitted when the focused client closed")
    assert(unfocused == c, "unfocus was emitted for the wrong client")
    assert(valid_at_unfocus, "client should still be valid when unfocus fires")

    assert(events[1] == "property::active",
        "expected property::active first, got " .. tostring(events[1]))
    assert(events[2] == "unfocus",
        "expected unfocus before request::unmanage, got " .. tostring(events[2]))
    assert(events[3] == "request::unmanage",
        "expected request::unmanage last, got " .. tostring(events[3]))
    assert(#events == 3, "expected exactly 3 events, got " .. #events)

    runner.done()
end)
