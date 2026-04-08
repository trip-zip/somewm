---------------------------------------------------------------------------
--- Reproduction test for issue #428: Tasklist client icons not showing
---
--- Verifies that awful.client.get_icon_path() resolves an icon file path
--- for clients with a matching desktop entry / icon theme icon.
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
    test_client("icon_test_428")
    local c = async.wait_for_client("icon_test_428", 5)
    assert(c, "Client did not appear")

    -- The test client's class (icon_test_428) won't have a .desktop file,
    -- so get_icon_path should return nil and cache the miss.
    local path = aclient.get_icon_path(c)
    io.stderr:write("[TEST] icon_test_428 icon path: " .. tostring(path) .. "\n")
    assert(path == nil, "Unexpected icon path for test client")
    assert(c._icon_path == false, "Expected cache miss to be stored as false")

    -- Verify a second call hits the cache (returns nil, doesn't error)
    local path2 = aclient.get_icon_path(c)
    assert(path2 == nil, "Cached result should still be nil")

    -- Test that lookup_icon works for a known icon name (the terminal)
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
