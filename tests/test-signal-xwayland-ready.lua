---------------------------------------------------------------------------
-- Test: xwayland::ready signal + awesome.xwayland_ready property
--
-- Covers:
--   * awesome.xwayland_ready is false in a fresh compositor: XWayland
--     starts lazily, on the first X client.
--   * Starting an X client (test-x11-grab-client) fires xwayland::ready
--     once and turns awesome.xwayland_ready true.
--   * The flag stays true and the signal does not fire again.
--
-- The client is not required to map: this covers the signal and the flag.
-- A missing Xwayland binary fails step 2.
---------------------------------------------------------------------------
-- timeout: 30
-- luacheck: globals awesome.log_level

local runner = require("_runner")
local awful = require("awful")

awesome.log_level = "debug"

local GRAB_CLIENT = "./build-test/test-x11-grab-client"
local CLASS = "xwayland_ready_probe"

local ready_count = 0
awesome.connect_signal("xwayland::ready", function()
    ready_count = ready_count + 1
end)

assert(awesome.xwayland_ready == false,
    "xwayland_ready is true before any X client connected")

local steps = {
    -- Step 1: start the first X client.
    function()
        local f = io.open(GRAB_CLIENT, "r")
        assert(f, GRAB_CLIENT .. " not found")
        f:close()
        local pid = awful.spawn(string.format(
            "%s /dev/null %s 0 0 50 50", GRAB_CLIENT, CLASS))
        assert(type(pid) == "number", "spawn failed: " .. tostring(pid))
        return true
    end,

    -- Step 2: the signal fires and the flag turns true (100 polls, ~10 s).
    function(count)
        if ready_count == 1 and awesome.xwayland_ready then
            return true
        end
        if count >= 100 then
            error(string.format(
                "after 100 polls: xwayland::ready fired %d times (want 1), "
                .. "awesome.xwayland_ready is %s (want true)",
                ready_count, tostring(awesome.xwayland_ready)))
        end
    end,

    -- Step 3: the flag is set once and the signal fires once.
    function(count)
        assert(awesome.xwayland_ready == true,
            "xwayland_ready went back to false")
        assert(ready_count == 1,
            "xwayland::ready fired " .. ready_count .. " times")
        if count >= 5 then
            return true
        end
    end,

    -- Step 4: kill the probe if it mapped.
    function()
        for _, c in ipairs(client.get()) do
            if c.class == CLASS then
                c:kill()
            end
        end
        return true
    end,
}

runner.run_steps(steps, { kill_clients = false, wait_per_step = 12 })

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
