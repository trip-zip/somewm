---------------------------------------------------------------------------
--- Test: carousel reflects its clients into the merged screen solve.
---
--- carousel positions its clients itself (viewport-relative, animated) but also
--- writes each client's box to p.geometries, which compose_screen reflects as
--- root-attached leaves. So carousel drives a "merged" screen solve and its
--- clients reach the tree==scene assertion. Run under SOMEWM_TREE_ASSERT=abort:
--- carousel is a descriptor-less documented leaf, so the assertion allow-lists
--- it (snapping the scroll so the snapshot matches the scene keeps it green).
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

local carousel = require("awful.layout.suit.carousel")
local function counts() return _somewm_clay.get_solve_counts() end

local CLASSES = { "car_a", "car_b", "car_c" }
local tag

local steps = {
    function()
        tag = screen.primary.tags[1]
        tag:view_only()
        tag.gap = 0
        carousel.scroll_duration = 0  -- snap: the snapshot equals the scene
        tag.layout = awful.layout.suit.carousel
        return true
    end,
    function(count)
        if count == 1 then
            for _, cls in ipairs(CLASSES) do test_client(cls) end
        end
        local n = 0
        for _, cls in ipairs(CLASSES) do
            if utils.find_client_by_class(cls) then n = n + 1 end
        end
        return n == #CLASSES and true or nil
    end,
    function(count)
        if count == 1 then
            _somewm_clay.reset_solve_counts()
            awful.layout.arrange(screen.primary)
            return nil
        end
        if counts().merged < 1 and count < 10 then return nil end
        assert(counts().merged >= 1,
            "carousel should reflect its clients into the merged screen solve")
        local wa = screen.primary.workarea
        local first_w, xs = nil, {}
        for _, cls in ipairs(CLASSES) do
            local c = utils.find_client_by_class(cls)
            local g = c:geometry()
            assert(g.height > 1, "carousel client " .. cls .. " has no height")
            -- The columns share one width_fraction, so equal widths. The
            -- corruption this test guards (a reflected off-screen column culled
            -- to a 1px box) showed up as one column 1px wide and another full,
            -- which an equal-width check catches where "positive size" did not.
            first_w = first_w or g.width
            assert(math.abs(g.width - first_w) <= 2, string.format(
                "carousel columns should be equal width; %s=%d vs %d",
                cls, g.width, first_w))
            assert(g.y >= wa.y - 4 and g.y < wa.y + wa.height,
                "carousel client " .. cls .. " should sit in the stack band")
            xs[#xs + 1] = g.x
        end
        -- Distinct scroll positions: the corruption stacked two columns at x=0.
        assert(not (xs[1] == xs[2] and xs[2] == xs[3]),
            "carousel columns should be at distinct x; got " .. table.concat(xs, ","))
        io.stderr:write(
            "[TEST] PASS: carousel reflects its clients into the merged solve\n")
        return true
    end,
    function(count)
        if count == 1 then
            for _, c in ipairs(client.get()) do if c.valid then c:kill() end end
        end
        if #client.get() == 0 then return true end
        if count >= 10 then return true end
    end,
}

runner.run_steps(steps, { kill_clients = false })

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
