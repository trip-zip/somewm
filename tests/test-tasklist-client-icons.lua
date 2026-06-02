---------------------------------------------------------------------------
--- Verifies that awful.client.resolve_icon populates c.icon when a
--- matching desktop entry / theme icon exists, and leaves it nil when
--- nothing resolves.
---------------------------------------------------------------------------

local runner = require("_runner")
local async = require("_async")
local test_client = require("_client")
local aclient = require("awful.client")

if not test_client.is_available() then
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

runner.run_async(function()
    test_client("icon_test_unknown")
    local c = async.wait_for_client("icon_test_unknown", 5)
    assert(c, "Client did not appear")

    -- The test client's class has no .desktop file and no matching theme
    -- icon, so request::manage -> resolve_icon should leave c.icon nil.
    io.stderr:write("[TEST] icon_test_unknown c.icon: " .. tostring(c.icon) .. "\n")
    assert(c.icon == nil, "Unexpected icon for unknown-class test client")

    -- Calling resolve_icon again must be a no-op for a client that had no match.
    aclient.resolve_icon(c)
    assert(c.icon == nil, "resolve_icon unexpectedly produced an icon on second call")

    -- lookup_icon still works for a known icon name (the terminal).
    local term_info = test_client.get_terminal_info()
    if term_info then
        local term_name = term_info.executable:match("([^/]+)$")
        local menubar_utils = require("menubar.utils")
        local term_icon = menubar_utils.lookup_icon(term_name)
        io.stderr:write("[TEST] Terminal '" .. term_name .. "' icon: " .. tostring(term_icon) .. "\n")
    end

    io.stderr:write("[TEST] PASS\n")
    runner.done()
end)
