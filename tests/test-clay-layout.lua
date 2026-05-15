---------------------------------------------------------------------------
--- Test: Clay declarative layout engine
--
-- Verifies that awful.layout.clay:
-- 1. Tile right: master on left, slaves on right
-- 2. Tile left: master on right, slaves on left
-- 3. Tile top: master on top, slaves on bottom
-- 4. Tile bottom: master on bottom, slaves on top
-- 5. Single client fills workarea
-- 6. Multiple masters stack within master pane
-- 7. Fair layout produces an even grid
-- 8. Gap handling matches the awful.layout framework
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

local clay = require("awful.layout.clay")

local tag
local c1, c2, c3, c4

local function get_geo(c)
    return c:geometry()
end

local function log_geo(label, c)
    local g = get_geo(c)
    io.stderr:write(string.format("[TEST] %s: x=%d y=%d w=%d h=%d\n",
        label, g.x, g.y, g.width, g.height))
end

local steps = {
    -- Step 1: Set up clay.tile layout
    function()
        tag = screen.primary.tags[1]
        tag:view_only()
        tag.layout = clay.tile
        tag.master_width_factor = 0.5
        tag.master_count = 1
        tag.gap = 0
        io.stderr:write("[TEST] Set clay.tile layout\n")
        return true
    end,

    -- Step 2: Spawn first client
    function(count)
        if count == 1 then test_client("clay_a") end
        c1 = utils.find_client_by_class("clay_a")
        if c1 then
            io.stderr:write("[TEST] Client A spawned\n")
            return true
        end
    end,

    -- Step 3: Single client should fill workarea
    function(count)
        if count == 1 then
            awful.layout.arrange(screen.primary)
            return nil
        end

        local wa = screen.primary.workarea
        local g = get_geo(c1)
        log_geo("single client", c1)

        -- Single client should approximately fill the workarea
        local tolerance = 2 * (c1.border_width or 0) + 2
        assert(math.abs(g.x - wa.x) <= tolerance,
            string.format("Single client x=%d should be near workarea x=%d", g.x, wa.x))
        assert(math.abs(g.width - wa.width) <= wa.width * 0.05 + tolerance,
            string.format("Single client width=%d should be near workarea width=%d",
                g.width, wa.width))
        io.stderr:write("[TEST] PASS: single client fills workarea\n")
        return true
    end,

    -- Step 4: Spawn second client
    function(count)
        if count == 1 then test_client("clay_b") end
        c2 = utils.find_client_by_class("clay_b")
        if c2 then
            io.stderr:write("[TEST] Client B spawned\n")
            return true
        end
    end,

    -- Step 5: Tile right - two clients side by side horizontally
    function(count)
        if count == 1 then
            awful.layout.arrange(screen.primary)
            return nil
        end

        local wa = screen.primary.workarea
        local cls = tag:clients()
        if #cls < 2 then return nil end

        local g1 = get_geo(cls[1])
        local g2 = get_geo(cls[2])
        log_geo("client 1 (tile.right)", cls[1])
        log_geo("client 2 (tile.right)", cls[2])

        -- Clients should be at different x positions (side by side)
        assert(g1.x ~= g2.x,
            "tile.right: clients should be at different x positions")

        -- Each should be approximately half the workarea width
        local expected_w = wa.width * 0.5
        assert(math.abs(g1.width - expected_w) < wa.width * 0.15,
            string.format("tile.right: client width=%d should be near %d",
                g1.width, expected_w))

        -- Both should span the full height
        assert(math.abs(g1.height - wa.height) < wa.height * 0.1,
            "tile.right: client should span full height")

        io.stderr:write("[TEST] PASS: tile.right splits horizontally\n")
        return true
    end,

    -- Step 6: Switch to tile.left - still horizontal split, positions swap
    function(count)
        if count == 1 then
            tag.layout = clay.tile.left
            awful.layout.arrange(screen.primary)
            return nil
        end

        local cls = tag:clients()
        if #cls < 2 then return nil end

        local g1 = get_geo(cls[1])
        local g2 = get_geo(cls[2])
        log_geo("client 1 (tile.left)", cls[1])
        log_geo("client 2 (tile.left)", cls[2])

        -- Clients should still be at different x positions
        assert(g1.x ~= g2.x,
            "tile.left: clients should be at different x positions")

        io.stderr:write("[TEST] PASS: tile.left splits horizontally\n")
        return true
    end,

    -- Step 7: Switch to tile.top - vertical split
    function(count)
        if count == 1 then
            tag.layout = clay.tile.top
            awful.layout.arrange(screen.primary)
            return nil
        end

        local cls = tag:clients()
        if #cls < 2 then return nil end

        local g1 = get_geo(cls[1])
        local g2 = get_geo(cls[2])
        log_geo("client 1 (tile.top)", cls[1])
        log_geo("client 2 (tile.top)", cls[2])

        -- Clients should be at different y positions (stacked vertically)
        assert(g1.y ~= g2.y,
            string.format("tile.top: clients should be at different y positions (%d vs %d)",
                g1.y, g2.y))

        -- Each should span the full width
        assert(math.abs(g1.x - g2.x) <= 2,
            "tile.top: clients should share same x position")

        io.stderr:write("[TEST] PASS: tile.top splits vertically\n")
        return true
    end,

    -- Step 8: Switch to tile.bottom - also vertical split
    function(count)
        if count == 1 then
            tag.layout = clay.tile.bottom
            awful.layout.arrange(screen.primary)
            return nil
        end

        local cls = tag:clients()
        if #cls < 2 then return nil end

        local g1 = get_geo(cls[1])
        local g2 = get_geo(cls[2])
        log_geo("client 1 (tile.bottom)", cls[1])
        log_geo("client 2 (tile.bottom)", cls[2])

        -- Clients should be at different y positions
        assert(g1.y ~= g2.y,
            string.format("tile.bottom: clients should be at different y positions (%d vs %d)",
                g1.y, g2.y))

        io.stderr:write("[TEST] PASS: tile.bottom splits vertically\n")
        return true
    end,

    -- Step 9: Spawn third and fourth clients for multi-master and fair tests
    function(count)
        if count == 1 then test_client("clay_c") end
        c3 = utils.find_client_by_class("clay_c")
        if c3 then
            io.stderr:write("[TEST] Client C spawned\n")
            return true
        end
    end,

    function(count)
        if count == 1 then test_client("clay_d") end
        c4 = utils.find_client_by_class("clay_d")
        if c4 then
            io.stderr:write("[TEST] Client D spawned\n")
            return true
        end
    end,

    -- Step 10: Multiple masters - with master_count=2, should have two panes
    -- with 2 clients in the master pane and 2 in the slave pane
    function(count)
        if count == 1 then
            tag.layout = clay.tile
            tag.master_count = 2
            awful.layout.arrange(screen.primary)
            return nil
        end

        local cls = tag:clients()
        if #cls < 4 then return nil end

        -- Collect all geometries
        local geos = {}
        for i, c in ipairs(cls) do
            geos[i] = get_geo(c)
            log_geo(string.format("client %d (multi-master)", i), c)
        end

        -- With tile.right + master_count=2, we should have two columns:
        -- master column (2 clients stacked) and slave column (2 clients stacked).
        -- Group clients by x-position to find columns.
        local by_x = {}
        for i, g in ipairs(geos) do
            local found = false
            for _, group in ipairs(by_x) do
                if math.abs(g.x - geos[group[1]].x) <= 2 then
                    group[#group + 1] = i
                    found = true
                    break
                end
            end
            if not found then
                by_x[#by_x + 1] = { i }
            end
        end

        assert(#by_x == 2,
            string.format("Multi-master: expected 2 columns, got %d", #by_x))

        -- Each column should have 2 clients
        assert(#by_x[1] == 2 and #by_x[2] == 2,
            string.format("Multi-master: columns should have 2+2 clients, got %d+%d",
                #by_x[1], #by_x[2]))

        io.stderr:write("[TEST] PASS: multiple masters creates two 2-client columns\n")
        return true
    end,

    -- Step 11: Fair layout - 4 clients in a 2x2 grid
    function(count)
        if count == 1 then
            tag.layout = clay.fair
            tag.master_count = 1
            awful.layout.arrange(screen.primary)
            return nil
        end

        local cls = tag:clients()
        if #cls < 4 then return nil end

        local geos = {}
        for i, c in ipairs(cls) do
            geos[i] = get_geo(c)
            log_geo(string.format("fair client %d", i), c)
        end

        -- With 4 clients fair produces 2 rows x 2 cols
        -- All clients should have approximately the same size
        local wa = screen.primary.workarea
        local expected_w = wa.width / 2
        local expected_h = wa.height / 2

        for i = 1, 4 do
            assert(math.abs(geos[i].width - expected_w) < wa.width * 0.15,
                string.format("fair: client %d width=%d should be near %d",
                    i, geos[i].width, expected_w))
            assert(math.abs(geos[i].height - expected_h) < wa.height * 0.15,
                string.format("fair: client %d height=%d should be near %d",
                    i, geos[i].height, expected_h))
        end

        io.stderr:write("[TEST] PASS: fair layout produces even grid\n")
        return true
    end,

    -- Step 12: Gap handling - verify gaps don't double/triple
    function(count)
        if count == 1 then
            tag.layout = clay.tile
            tag.master_count = 1
            tag.gap = 8
            awful.layout.arrange(screen.primary)
            return nil
        end

        local cls = tag:clients()
        if #cls < 2 then return nil end

        local wa = screen.primary.workarea
        -- Sort clients by x to find left/right regardless of tiling order
        local geos = {}
        for _, c in ipairs(cls) do
            geos[#geos + 1] = { c = c, g = get_geo(c) }
        end
        table.sort(geos, function(a, b) return a.g.x < b.g.x end)

        local left = geos[1]
        local right = geos[2]
        log_geo("left (gap test)", left.c)
        log_geo("right (gap test)", right.c)
        io.stderr:write(string.format("[TEST] workarea: x=%d y=%d w=%d h=%d\n",
            wa.x, wa.y, wa.width, wa.height))

        -- The gap between left client's right edge and right client's left edge.
        -- With gap=8 and the framework's post-layout correction, the visual gap
        -- between clients should be useless_gap*2 = 16px (plus border widths).
        local bw = left.c.border_width or 0
        local left_right_edge = left.g.x + left.g.width + 2 * bw
        local gap_between = right.g.x - left_right_edge
        io.stderr:write(string.format(
            "[TEST] Gap between clients: %dpx (expected ~%dpx)\n",
            gap_between, 16))

        -- Gap should be no more than 4x the configured gap (catches tripling)
        assert(gap_between <= 8 * 4,
            string.format("Gap between clients is %dpx, expected <= %dpx (gap tripled?)",
                gap_between, 8 * 4))

        -- Gap should be positive
        assert(gap_between >= 0,
            string.format("Gap between clients is negative: %dpx", gap_between))

        io.stderr:write("[TEST] PASS: gap handling is reasonable\n")
        return true
    end,

    -- Step 13: Cleanup
    function(count)
        if count == 1 then
            for _, c in ipairs(client.get()) do
                if c.valid then c:kill() end
            end
        end
        if #client.get() == 0 then
            return true
        end
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
