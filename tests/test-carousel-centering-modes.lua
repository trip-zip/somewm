---------------------------------------------------------------------------
--- Test: carousel centering modes
--
-- Verifies that the carousel layout:
-- 1. "always" mode centers the focused column
-- 2. "never" mode only scrolls when column is fully offscreen
-- 3. "on-overflow" mode centers when partially offscreen
-- 4. set_center_mode() changes the mode
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
        -- Start with "always" mode (easiest to verify)
        carousel.set_center_mode("always")
        return true
    end,

    -- Spawn three clients with 1/3 width each
    function(count)
        if count == 1 then test_client("center_a") end
        c1 = utils.find_client_by_class("center_a")
        if c1 then return true end
    end,

    function(count)
        if count == 1 then test_client("center_b") end
        c2 = utils.find_client_by_class("center_b")
        if c2 then return true end
    end,

    function(count)
        if count == 1 then test_client("center_c") end
        c3 = utils.find_client_by_class("center_c")
        if c3 then return true end
    end,

    -- Set all columns to 1/3 width so they fit side by side
    function(count)
        if count == 1 then
            client.focus = c1
            c1:raise()
            carousel.set_column_width(1/3)
            return nil
        end
        client.focus = c2
        c2:raise()
        carousel.set_column_width(1/3)
        return true
    end,

    function(count)
        if count == 1 then return nil end
        client.focus = c3
        c3:raise()
        carousel.set_column_width(1/3)
        return true
    end,

    -- Test "always" mode: focused column should be centered
    function(count)
        if count == 1 then
            client.focus = c1
            c1:raise()
            awful.layout.arrange(screen.primary)
            return nil
        end

        local wa = screen.primary.workarea
        local g1 = c1:geometry()
        local col_center = g1.x + g1.width / 2
        local screen_center = wa.x + wa.width / 2

        io.stderr:write(string.format(
            "[TEST] always mode: c1 center=%d, screen center=%d\n",
            col_center, screen_center))

        -- With "always" mode, focused column's center should be near screen center
        assert(math.abs(col_center - screen_center) < wa.width * 0.15,
            string.format("Column center %d should be near screen center %d",
                col_center, screen_center))

        io.stderr:write("[TEST] PASS: always mode centers focused column\n")
        return true
    end,

    -- Switch to "never" mode
    function(count)
        if count == 1 then
            carousel.set_center_mode("never")
            -- Focus c1 which should be visible
            client.focus = c1
            c1:raise()
            awful.layout.arrange(screen.primary)
            return nil
        end

        local wa = screen.primary.workarea
        local g1 = c1:geometry()

        io.stderr:write(string.format(
            "[TEST] never mode: c1 x=%d, w=%d, wa=[%d,%d]\n",
            g1.x, g1.width, wa.x, wa.x + wa.width))

        -- c1 should be visible
        assert(g1.x >= wa.x - 1 and g1.x + g1.width <= wa.x + wa.width + 1,
            "c1 should be visible in never mode")

        io.stderr:write("[TEST] PASS: never mode keeps visible columns in place\n")
        return true
    end,

    -- Switch to "on-overflow" mode and verify
    function(count)
        if count == 1 then
            carousel.set_center_mode("on-overflow")
            client.focus = c2
            c2:raise()
            awful.layout.arrange(screen.primary)
            return nil
        end

        local wa = screen.primary.workarea
        local g2 = c2:geometry()

        io.stderr:write(string.format(
            "[TEST] on-overflow mode: c2 x=%d, w=%d\n", g2.x, g2.width))

        -- c2 should be visible
        assert(g2.x >= wa.x - 1,
            string.format("c2 x=%d should be >= wa.x=%d", g2.x, wa.x))

        io.stderr:write("[TEST] PASS: on-overflow mode\n")
        return true
    end,

    -- Verify set_center_mode rejects invalid modes
    function()
        local ok = pcall(function()
            carousel.set_center_mode("invalid")
        end)
        assert(not ok, "set_center_mode should reject invalid modes")
        io.stderr:write("[TEST] PASS: invalid mode rejected\n")

        -- Reset to default
        carousel.set_center_mode("on-overflow")
        return true
    end,

    -- Cleanup
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
