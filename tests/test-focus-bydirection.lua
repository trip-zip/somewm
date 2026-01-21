-- Test for https://github.com/awesomeWM/awesome/pull/3225

local runner = require("_runner")
local awful = require("awful")
local test_client = require("_client")

-- Skip if no test client available
if not test_client.is_available() then
    io.stderr:write("SKIP: no terminal available for test clients\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

-- Ensure clients are placed next to each other horizontally
-- fair.horizontal creates a grid that gives each client a distinct x position
awful.screen.focused().selected_tag.layout = awful.layout.suit.fair.horizontal


local cleft, cright, cmid

-- Find clients for left-right navigation
-- We need two clients in the same row for meaningful left-right testing
local function find_horizontal_pair()
    local clients = client.get()
    if #clients < 3 then return nil end

    -- Find two clients in the same row (similar y position)
    table.sort(clients, function(a, b)
        return a:geometry().x < b:geometry().x
    end)

    -- Find clients that share approximately the same y position
    for i = 1, #clients do
        for j = i + 1, #clients do
            local ci, cj = clients[i], clients[j]
            local yi, yj = ci:geometry().y, cj:geometry().y
            -- Same row if y positions within 50px
            if math.abs(yi - yj) < 50 then
                -- ci is left, cj is right (since sorted by x)
                -- Find a third client to be "mid" (will be unfocusable)
                for k = 1, #clients do
                    if k ~= i and k ~= j then
                        return ci, cj, clients[k]
                    end
                end
            end
        end
    end
    return nil
end

local steps = {
    -- Step 1: Spawn 3 test clients and wait for them
    function(count)
        if count == 1 then
            test_client("bydirection_a")
            test_client("bydirection_b")
            test_client("bydirection_c")
        end
        if #client.get() >= 3 then
            return true
        end
        return nil
    end,

    -- Step 1b: Wait for tiling to settle and identify clients by position
    function(count)
        if count == 1 then
            -- Force layout refresh
            awful.layout.arrange(awful.screen.focused())
        end

        -- Give layout time to arrange clients (visual mode needs this)
        if count < 5 then
            return nil
        end

        cleft, cright, cmid = find_horizontal_pair()
        if cleft and cright and cmid then
            -- Verify cleft is actually to the left of cright
            local lx = cleft:geometry().x
            local rx = cright:geometry().x
            if lx < rx then
                -- Make the third client unfocusable (even though it's not between left/right)
                cmid.focusable = false
                io.stderr:write(string.format("[TEST] Found horizontal pair: left=%s at x=%d, right=%s at x=%d\n",
                    cleft.class or "?", lx, cright.class or "?", rx))
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

runner.run_steps(steps, { wait_per_step = 5, kill_clients = false })

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
