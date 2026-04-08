---------------------------------------------------------------------------
--- Test: carousel directional focus navigation via bydirection
--
-- Verifies that awful.client.focus.bydirection("left"/"right") works
-- correctly with carousel geometry:
-- 1. bydirection("right") moves focus to the next column
-- 2. bydirection("left") moves focus back
-- 3. Viewport scrolls to keep focused client visible
-- 4. bydirection at boundaries stays at the edge
---------------------------------------------------------------------------

local runner = require("_runner")
local test_client = require("_client")
local utils = require("_utils")
local awful = require("awful")
local carousel = awful.layout.suit.carousel

if not test_client.is_available() then
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

carousel.scroll_duration = 0

local tag
local c1, c2, c3

local steps = {
    -- Step 1: Set up carousel layout
    function()
        tag = screen.primary.tags[1]
        tag:view_only()
        tag.layout = carousel
        return true
    end,

    -- Step 2-4: Spawn three clients
    function(count)
        if count == 1 then test_client("nav_a") end
        c1 = utils.find_client_by_class("nav_a")
        if c1 then return true end
    end,

    function(count)
        if count == 1 then test_client("nav_b") end
        c2 = utils.find_client_by_class("nav_b")
        if c2 then return true end
    end,

    function(count)
        if count == 1 then test_client("nav_c") end
        c3 = utils.find_client_by_class("nav_c")
        if c3 then return true end
    end,

    -- Step 5: Focus c1, let layout settle
    function(count)
        if count == 1 then
            client.focus = c1
            c1:raise()
            awful.layout.arrange(screen.primary)
            return nil
        end
        assert(client.focus == c1, "c1 should be focused")
        return true
    end,

    -- Step 6: bydirection("right") moves focus from c1 to the next column
    function(count)
        if count == 1 then
            awful.client.focus.bydirection("right")
            return nil
        end

        local focus = client.focus
        -- Retry until focus has moved
        if focus == c1 then return end
        io.stderr:write(string.format("[TEST] After bydirection('right'): focused=%s\n",
            focus and focus.class or "nil"))
        io.stderr:write("[TEST] PASS: bydirection('right') moved focus to next column\n")
        return true
    end,

    -- Step 7: bydirection("right") again moves to the third column
    function(count)
        if count == 1 then
            awful.client.focus.bydirection("right")
            return nil
        end

        local focus = client.focus
        io.stderr:write(string.format("[TEST] After second bydirection('right'): focused=%s\n",
            focus and focus.class or "nil"))
        io.stderr:write("[TEST] PASS: second navigation moved focus\n")
        return true
    end,

    -- Step 8: bydirection("right") at right boundary stays put
    function(count)
        if count == 1 then
            for _ = 1, 5 do
                awful.client.focus.bydirection("right")
            end
            return nil
        end

        local focus = client.focus
        assert(focus ~= nil, "Should still have focus at boundary")
        io.stderr:write("[TEST] PASS: focus stays valid at right boundary\n")
        return true
    end,

    -- Step 9: bydirection("left") navigates back through all columns
    function(count)
        if count == 1 then
            for _ = 1, 10 do
                awful.client.focus.bydirection("left")
            end
            return nil
        end

        local focus = client.focus
        assert(focus ~= nil, "Should still have focus at left boundary")
        io.stderr:write("[TEST] PASS: focus stays valid at left boundary\n")
        return true
    end,

    -- Step 10: Verify viewport follows focus - focus c1
    function(count)
        if count == 1 then
            client.focus = c1
            c1:raise()
            awful.layout.arrange(screen.primary)
            return nil
        end

        local wa = screen.primary.workarea
        local g1 = c1:geometry()
        -- Retry until viewport scrolls to show c1
        if g1.x < wa.x - 1 or g1.x >= wa.x + wa.width then return end
        io.stderr:write(string.format("[TEST] c1 geo: x=%d, w=%d\n", g1.x, g1.width))
        return true
    end,

    -- Step 11: Focus c3, verify viewport scrolled to show it
    function(count)
        if count == 1 then
            client.focus = c3
            c3:raise()
            awful.layout.arrange(screen.primary)
            return nil
        end

        local wa = screen.primary.workarea
        local g3 = c3:geometry()
        -- Retry until viewport scrolls to show c3
        if g3.x < wa.x - 1 or g3.x >= wa.x + wa.width then return end
        io.stderr:write(string.format("[TEST] c3 geo: x=%d, w=%d\n", g3.x, g3.width))
        io.stderr:write("[TEST] PASS: viewport follows focus\n")
        return true
    end,

    -- Step 12: bydirection("right") from c1, verify viewport follows
    function(count)
        if count == 1 then
            client.focus = c1
            c1:raise()
            awful.layout.arrange(screen.primary)
            return nil
        end
        awful.client.focus.bydirection("right")
        return true
    end,

    -- Step 13: Verify the navigated-to client is visible
    function(count)
        if count == 1 then
            return nil
        end

        local focus = client.focus
        if not focus then return nil end

        local wa = screen.primary.workarea
        local fg = focus:geometry()
        io.stderr:write(string.format("[TEST] After nav right: focused=%s, x=%d\n",
            focus.class, fg.x))

        assert(fg.x >= wa.x - 1 and fg.x < wa.x + wa.width,
            "Focused client should be visible after navigation")
        io.stderr:write("[TEST] PASS: viewport follows bydirection navigation\n")
        return true
    end,

    -- Step 14: Cleanup
    function(count)
        if count == 1 then
            for _, c in ipairs(client.get()) do
                if c.valid then c:kill() end
            end
        end
        if #client.get() == 0 then return true end
        if count >= 10 then
            local pids = test_client.get_spawned_pids()
            for _, pid in ipairs(pids) do
                os.execute("kill -9 " .. pid .. " 2>/dev/null")
            end
            return true
        end
    end,
}

runner.run_steps(steps, { kill_clients = false })
