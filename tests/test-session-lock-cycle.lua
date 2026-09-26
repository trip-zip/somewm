---------------------------------------------------------------------------
-- Test: an ext-session-lock client locks and unlocks the session.
--
-- The client's surface becomes a borrowed leaf in the output's one tree,
-- above the desktop, under the lock section. Unlocking removes the whole
-- section and the desktop comes back.
---------------------------------------------------------------------------

local runner = require("_runner")
local awful = require("awful")
local wibox = require("wibox")

local CLIENT = "./build-test/test-session-lock-client"

if not awful.spawn.with_line_callback then
    io.stderr:write("SKIP: awful.spawn.with_line_callback not available\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local f = io.open(CLIENT, "r")
if not f then
    io.stderr:write("SKIP: " .. CLIENT .. " not built\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end
f:close()

local s = screen[1]
local pid, said_locked, said_surface = nil, false, false

local function tree()
    local out = {}
    for line in awesome._clay_tree(s):gmatch("[^\n]+") do
        if line == "  realized:" then break end
        out[#out + 1] = line
    end
    return out
end

local function band_of(needle)
    for _, line in ipairs(tree()) do
        if line:find(needle, 1, true) then
            return tonumber(line:match(" band (%-?%d+)")) or -1, line
        end
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
                if line == "locked" then said_locked = true end
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
        if not (said_locked and said_surface) then
            assert(count < 60, "the lock client never reached its locked surface")
            return nil
        end
        io.stderr:write("[PASS] the lock client locked and committed a surface\n")
        return true
    end,

    -- The tree carries the lock section above the desktop, with the
    -- client's surface as its leaf.
    function(count)
        local backdrop = band_of("LOCK ")
        local surface, line = band_of("lock.surface")

        if not backdrop or not surface then
            assert(count < 40, "the lock section never reached the dump")
            return nil
        end
        assert(backdrop == 200, "the backdrop is at band " .. backdrop)
        assert(surface == 220, "the lock surface is at band " .. surface)
        local headers = 0
        for _, l in ipairs(tree()) do
            if l:match("^output %S+ scale") then headers = headers + 1 end
        end
        assert(headers == 1, "the dump has " .. headers .. " headers for one screen")
        io.stderr:write("[PASS] one tree, lock section on top: " .. line .. "\n")
        return true
    end,

    -- SIGUSR1 makes the client send unlock_and_destroy.
    function()
        os.execute("kill -USR1 " .. pid .. " 2>/dev/null")
        return true
    end,

    function(count)
        if band_of("LOCK ") then
            assert(count < 40, "the lock section outlived the unlock")
            return nil
        end
        assert(band_of("lock.surface") == nil, "the lock surface leaf stayed")
        assert(band_of("WIBAR screen"), "the desktop wibar did not come back")
        io.stderr:write("[PASS] unlock removes the lock section, the desktop stays\n")
        return true
    end,
})
