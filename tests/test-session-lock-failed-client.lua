---------------------------------------------------------------------------
-- Test: an ext-session-lock client that dies without unlocking.
--
-- The protocol says the session stays locked. The backdrop is the
-- compositor's own element, so it keeps covering the outputs with no lock
-- client at all, and nothing below it takes the pointer.
---------------------------------------------------------------------------

local runner = require("_runner")
local awful = require("awful")
local wibox = require("wibox")

local CLIENT = "./build-test/test-session-lock-client"

local f = io.open(CLIENT, "r")
if not f then
    io.stderr:write("SKIP: " .. CLIENT .. " not built\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end
f:close()

local s = screen[1]
local pid, said_surface = nil, false

local function tree()
    local out = {}
    for line in awesome._clay_tree(s):gmatch("[^\n]+") do
        if line == "  realized:" then break end
        out[#out + 1] = line
    end
    return out
end

local function find(needle)
    for _, line in ipairs(tree()) do
        if line:find(needle, 1, true) then return line end
    end
    return nil
end

runner.run_steps({
    function()
        local bar = awful.wibar({ position = "top", screen = s, height = 24 })
        bar:setup({
            layout = wibox.layout.fixed.horizontal,
            { widget = wibox.widget.textbox, text = "desktop" },
        })
        return true
    end,

    function()
        pid = awful.spawn.with_line_callback(CLIENT, {
            stdout = function(line)
                io.stderr:write("[client] " .. line .. "\n")
                if line:match("^surface ") then said_surface = true end
            end,
            stderr = function(line)
                io.stderr:write("[client stderr] " .. line .. "\n")
            end,
        })
        assert(type(pid) == "number", "spawn failed: " .. tostring(pid))
        return true
    end,

    function(count)
        if not said_surface then
            assert(count < 60, "the lock client never committed a surface")
            return nil
        end
        assert(find("lock.surface"), "the lock surface never reached the dump")
        return true
    end,

    -- SIGTERM, no unlock: the client is gone and the session is still locked.
    function()
        os.execute("kill -TERM " .. pid .. " 2>/dev/null")
        return true
    end,

    function(count)
        if find("lock.surface") then
            assert(count < 40, "the dead client's surface leaf stayed")
            return nil
        end
        local backdrop = find("LOCK ")
        assert(backdrop, "the backdrop went away with the lock client")
        assert(tonumber(backdrop:match(" band (%-?%d+)")) == 200,
            "the backdrop is not at band 200: " .. backdrop)
        io.stderr:write("[PASS] the session stays covered with no lock client: "
            .. backdrop .. "\n")
        return true
    end,

    -- The wibar is still declared under the backdrop, and still cannot be
    -- reached by the pointer.
    function(count)
        local g = s.geometry
        local x, y = g.x + math.floor(g.width / 2), g.y + 12

        assert(find("WIBAR screen"), "the desktop stopped being declared")
        mouse.coords({ x = x, y = y })
        if count < 3 then return nil end
        mouse.coords({ x = x, y = y })
        assert(mouse.object_under_pointer() == nil,
            "the wibar took the pointer through the lock")
        io.stderr:write("[PASS] the desktop is declared but answers nothing\n")
        return true
    end,
})
