---------------------------------------------------------------------------
-- Test: a lock client that requests its surfaces with the lock keeps
-- keyboard focus.
--
-- locksession() unfocuses the client, which leaves a focus update pending.
-- Quickshell sends lock and get_lock_surface in one flush, so the lock
-- surface got keyboard focus before that update ran, and the update then
-- cleared it: the session stayed locked with nothing able to type into it.
---------------------------------------------------------------------------

local runner = require("_runner")
local awful = require("awful")

local CLIENT = "./build-test/test-session-lock-client"

if not awful.spawn.with_line_callback then
    return runner.skip("awful.spawn.with_line_callback not available")
end

local f = io.open(CLIENT, "r")
if not f then
    return runner.skip(CLIENT .. " not built")
end
f:close()

local pid, said_surface, entered, left = nil, false, false, false

runner.run_steps({
    function()
        pid = awful.spawn.with_line_callback({ CLIENT, "--eager" }, {
            stdout = function(line)
                io.stderr:write("[client] " .. line .. "\n")
                if line:match("^surface ") then said_surface = true end
                if line == "keyboard enter" then entered, left = true, false end
                if line == "keyboard leave" then left = true end
            end,
            stderr = function(line)
                io.stderr:write("[client stderr] " .. line .. "\n")
            end,
        })
        assert(type(pid) == "number", "spawn failed: " .. tostring(pid))
        return true
    end,

    function(count)
        if not (said_surface and entered) then
            assert(count < 60, "the eager lock surface never got keyboard focus")
            return nil
        end
        return true
    end,

    -- Give the pending focus refresh several frames to (wrongly) clear it.
    function(count)
        assert(not left, "the lock surface lost keyboard focus while locked")
        if count < 10 then return nil end
        io.stderr:write("[PASS] the eager lock surface keeps keyboard focus\n")
        return true
    end,

    function()
        os.execute("kill -USR1 " .. pid .. " 2>/dev/null")
        return true
    end,
})
