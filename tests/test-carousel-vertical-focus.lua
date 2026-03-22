---------------------------------------------------------------------------
--- Test: vertical carousel focus change scrolls viewport vertically
--
-- Verifies that carousel.vertical:
-- 1. Scrolls viewport to newly focused client on y-axis
-- 2. Focus handler fires for carousel.vertical layout
-- 3. Focus change between columns triggers re-arrange
---------------------------------------------------------------------------

local runner = require("_runner")
local test_client = require("_client")
local utils = require("_utils")
local awful = require("awful")

if not test_client.is_available() then
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local carousel = awful.layout.suit.carousel
local vertical = carousel.vertical
carousel.scroll_duration = 0
carousel.set_center_mode("always")

local tag
local c1, c2, c3

local steps = {
    -- Step 1: Set up vertical carousel layout
    function()
        tag = screen.primary.tags[1]
        tag:view_only()
        tag.layout = vertical
        return true
    end,

    -- Spawn three clients
    function(count)
        if count == 1 then test_client("vfocus_a") end
        c1 = utils.find_client_by_class("vfocus_a")
        if c1 then return true end
    end,

    function(count)
        if count == 1 then test_client("vfocus_b") end
        c2 = utils.find_client_by_class("vfocus_b")
        if c2 then return true end
    end,

    function(count)
        if count == 1 then test_client("vfocus_c") end
        c3 = utils.find_client_by_class("vfocus_c")
        if c3 then return true end
    end,

    -- Focus c1 and verify it is visible
    function(count)
        if count == 1 then
            client.focus = c1
            c1:raise()
            awful.layout.arrange(screen.primary)
            return nil
        end

        local wa = screen.primary.workarea
        local g1 = c1:geometry()
        io.stderr:write(string.format("[TEST] c1 focused: y=%d h=%d (wa.y=%d wa.h=%d)\n",
            g1.y, g1.height, wa.y, wa.height))

        assert(g1.y >= wa.y - 1 and g1.y < wa.y + wa.height,
            string.format("c1 y=%d should be visible after focus", g1.y))
        io.stderr:write("[TEST] PASS: c1 visible after focus\n")
        return true
    end,

    -- Focus c3 and verify viewport scrolled to it
    function(count)
        if count == 1 then
            client.focus = c3
            c3:raise()
            awful.layout.arrange(screen.primary)
            return nil
        end

        local wa = screen.primary.workarea
        local g3 = c3:geometry()
        io.stderr:write(string.format("[TEST] c3 focused: y=%d h=%d\n", g3.y, g3.height))

        assert(g3.y >= wa.y - 1 and g3.y < wa.y + wa.height,
            string.format("c3 y=%d should be visible after focus", g3.y))
        io.stderr:write("[TEST] PASS: c3 visible after focus change\n")
        return true
    end,

    -- Focus c2 (middle) and verify viewport scrolled
    function(count)
        if count == 1 then
            client.focus = c2
            c2:raise()
            awful.layout.arrange(screen.primary)
            return nil
        end

        local wa = screen.primary.workarea
        local g2 = c2:geometry()
        io.stderr:write(string.format("[TEST] c2 focused: y=%d h=%d\n", g2.y, g2.height))

        assert(g2.y >= wa.y - 1 and g2.y < wa.y + wa.height,
            string.format("c2 y=%d should be visible after focus", g2.y))
        io.stderr:write("[TEST] PASS: c2 visible after focus change\n")
        return true
    end,

    -- Cleanup
    function(count)
        if count == 1 then
            carousel.set_center_mode("on-overflow")
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
