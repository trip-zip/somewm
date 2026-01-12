-- Test for https://github.com/awesomeWM/awesome/pull/3225

local runner = require("_runner")
local awful = require("awful")
local beautiful = require("beautiful")

-- Ensure clients are placed next to each other
beautiful.column_count = 3
awful.screen.focused().selected_tag.layout = awful.layout.suit.tile


local cleft, cmid, cright

-- Find the leftmost and rightmost clients by geometry
local function find_left_right_clients()
    local clients = client.get()
    if #clients < 3 then return nil end

    -- Sort by x position
    table.sort(clients, function(a, b)
        return a:geometry().x < b:geometry().x
    end)

    return clients[1], clients[2], clients[3]
end

local steps = {
    -- Step 1: Spawn 3 xterms and wait for them
    function(count)
        if count == 1 then
            awful.spawn("xterm")
            awful.spawn("xterm")
            awful.spawn("xterm")
        end
        if #client.get() >= 3 then
            cleft, cmid, cright = find_left_right_clients()
            if cleft and cmid and cright then
                cmid.focusable = false
                return true
            end
        end
        return nil
    end,

    -- Step 2: Set focus to left client and wait
    function(count)
        if count == 1 then
            client.focus = cleft
        end
        if client.focus == cleft then
            return true
        end
        if count > 10 then
            error("Could not focus left client")
        end
        return nil
    end,

    -- Step 3: Test bydirection and wait for focus change
    function(count)
        if count == 1 then
            awful.client.focus.bydirection("right")
        end
        if client.focus == cright then
            return true
        end
        if count > 10 then
            error(string.format("bydirection failed: expected cright, got %s",
                client.focus and client.focus.class or "nil"))
        end
        return nil
    end,

    -- Step 4: Reset focus to left and wait
    function(count)
        if count == 1 then
            client.focus = cleft
        end
        if client.focus == cleft then
            return true
        end
        if count > 10 then
            error("Could not focus left client for global_bydirection test")
        end
        return nil
    end,

    -- Step 5: Test global_bydirection and wait for focus change
    function(count)
        if count == 1 then
            awful.client.focus.global_bydirection("right")
        end
        if client.focus == cright then
            return true
        end
        if count > 10 then
            error(string.format("global_bydirection failed: expected cright, got %s",
                client.focus and client.focus.class or "nil"))
        end
        return nil
    end,
}

runner.run_steps(steps)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
