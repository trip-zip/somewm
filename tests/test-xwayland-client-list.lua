-- client.get() lists a client from its first map: the first X client of the
-- session is the only listed client while it lives, and the list is empty
-- once it is killed.
local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local utils = require('_utils')

if os.getenv("WLR_BACKENDS") == "headless" then
    io.stderr:write("SKIP: XWayland tests require visual mode (HEADLESS=0)\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local GRAB_CLIENT = utils.binary_or_skip('./build-test/test-x11-grab-client')
if not GRAB_CLIENT then return end

runner.run_async(function()
    assert(#client.get() == 0, 'list not empty at start')

    local pid = awful.spawn(string.format("%s /dev/null first_x11 0 0 50 50", GRAB_CLIENT))
    assert(type(pid) == "number", "spawn failed: " .. tostring(pid))
    local wc
    async.wait_for_condition(function()
        for _, c in ipairs(client.get()) do
            if c.name == "first_x11" then wc = c; return true end
        end
    end, 10)
    assert(wc, "first X client did not appear")
    assert(#client.get() == 1, 'list holds more than the mapped client: ' .. #client.get())

    os.execute("kill -9 " .. pid .. " 2>/dev/null")
    async.wait_for_condition(function() return not wc.valid end, 5)
    assert(async.wait_for_condition(function() return #client.get() == 0 end, 5),
           'list not empty after the only X client was killed: ' .. #client.get())

    runner.done()
end)
