---------------------------------------------------------------------------
--- root.fake_input scroll and extra buttons (X11 numbering parity).
---
--- X11 buttons 4-7 are scroll: fake_input must synthesize one axis tick on
--- press (release is a no-op). It used to send BTN_SIDE/BTN_EXTRA/
--- BTN_FORWARD/BTN_BACK presses instead. Button 8+ maps to BTN_SIDE and up.
---
--- test-pointer-logger maps an xdg_toplevel and appends every wl_pointer
--- event it receives to a marker file: axis <axis> <value> / button <code>
--- <state> / enter / motion / leave.
---------------------------------------------------------------------------

local runner = require("_runner")
local async  = require("_async")
local awful  = require("awful")
local utils  = require("_utils")

-- The headless backend (CI) has no pointer device and never delivers
-- wl_pointer events to clients, so skip there (run it headful).
if utils.is_headless() then
    io.stderr:write("SKIP: needs a real pointer device (headless backend has none)\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local CLIENT = utils.binary_or_skip("./build-test/test-pointer-logger")
if not CLIENT then return end

local APP_ID = "fakescroll"
local marker = string.format("/tmp/somewm-fakescroll-%d.log", os.time())
os.remove(marker)

local function clear_marker()
    local f = io.open(marker, "w"); if f then f:close() end
end

local function read_lines()
    local f = io.open(marker, "r"); if not f then return {} end
    local out = {}
    for line in f:lines() do out[#out + 1] = line end
    f:close()
    return out
end

runner.run_async(function()
    local spawn_pid = awful.spawn(string.format("%s --app-id %s --marker %s",
                                                CLIENT, APP_ID, marker))
    assert(type(spawn_pid) == "number", "spawn returned: " .. tostring(spawn_pid))

    local c = async.wait_for_client(APP_ID, 5)
    assert(c, "pointer-logger client did not appear")

    c.floating = true
    async.sleep(0.05)
    c:geometry({ x = 200, y = 200, width = 600, height = 400 })
    async.sleep(0.2)

    -- Park the cursor over the client so fake_input focuses its surface.
    local g = c:geometry()
    mouse.coords({ x = g.x + 300, y = g.y + 200 })
    async.sleep(0.1)

    -- One press+release; return the wl_pointer lines it produced.
    local function fake_click(button)
        clear_marker()
        root.fake_input("button_press", button)
        root.fake_input("button_release", button)
        async.wait_for_condition(function() return #read_lines() > 0 end, 5)
        async.sleep(0.2)  -- allow any (unwanted) second event to arrive
        local out = {}
        for _, line in ipairs(read_lines()) do
            if not line:match("^enter") and not line:match("^motion")
               and not line:match("^leave") then
                out[#out + 1] = line
            end
        end
        return out
    end

    -- Buttons 4-7: exactly one axis tick, no button events.
    for _, case in ipairs({
        { button = 4, expect = "axis 0 %-15" },
        { button = 5, expect = "axis 0 15" },
        { button = 6, expect = "axis 1 %-15" },
        { button = 7, expect = "axis 1 15" },
    }) do
        local ev = fake_click(case.button)
        assert(#ev == 1 and ev[1]:match("^" .. case.expect .. "$"),
            string.format("button %d: expected one '%s', got [%s]",
                case.button, case.expect:gsub("%%", ""),
                table.concat(ev, " | ")))
    end

    -- Buttons 8-11: press+release of BTN_SIDE..BTN_BACK (275..278).
    for x11 = 8, 11 do
        local code = 275 + (x11 - 8)
        local ev = fake_click(x11)
        assert(#ev == 2 and ev[1] == ("button %d 1"):format(code)
                        and ev[2] == ("button %d 0"):format(code),
            string.format("button %d: expected button %d press+release, got [%s]",
                x11, code, table.concat(ev, " | ")))
    end

    io.stderr:write("[ALL TESTS] PASS\n")

    if c.valid then c:kill() end
    if spawn_pid then os.execute("kill -9 " .. spawn_pid .. " 2>/dev/null") end
    async.wait_for_no_clients(5)
    os.remove(marker)
    runner.done()
end)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
