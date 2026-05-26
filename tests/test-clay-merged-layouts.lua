---------------------------------------------------------------------------
--- Test: the flexbox-expressible built-in layouts join the merged screen
--- solve, while arbitrary custom user layouts keep working via the
--- non-merged escape hatch.
---
--- fair/spiral/corner/max are merge_capable (Step 3): compose_screen grafts
--- their client subtree and solves the whole screen once (source "merged"),
--- so the standalone "preset" solve no longer fires for them. max.fullscreen
--- joins them in Step 4 via the floating-to-root graft, covering
--- screen.geometry rather than the workarea. Arbitrary custom user layouts
--- (Prime Directive) stay on the non-merged path.
---
--- arrange() runs through a delayed_call, so each measurement resets the
--- counters, triggers an arrange, and polls until the solve lands.
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

local CLASSES = { "ml_a", "ml_b", "ml_c", "ml_d" }
local tag

local function counts()
    return _somewm_clay.get_solve_counts()
end

-- Every client on the tag should land inside the workarea (gap is 0). max
-- overlaps all clients there; the split/grid layouts partition it.
local function assert_clients_within_workarea(label)
    local wa = screen.primary.workarea
    for _, c in ipairs(tag:clients()) do
        local g = c:geometry()
        local tol = 2 * (c.border_width or 0) + 4
        assert(g.x >= wa.x - tol and g.y >= wa.y - tol
            and g.x + g.width  <= wa.x + wa.width  + tol
            and g.y + g.height <= wa.y + wa.height + tol,
            string.format(
                "%s: client %s geo %dx%d+%d+%d escapes workarea %dx%d+%d+%d",
                label, tostring(c.class), g.width, g.height, g.x, g.y,
                wa.width, wa.height, wa.x, wa.y))
    end
end

-- Two steps for a merge-capable layout: select it, then reset+arrange and
-- assert the screen solve was tagged "merged" (not the standalone "preset").
local function merged_layout_steps(label, layout)
    return {
        function()
            tag.layout = layout
            return true
        end,
        function(count)
            if count == 1 then
                _somewm_clay.reset_solve_counts()
                awful.layout.arrange(screen.primary)
                return nil
            end
            local c = counts()
            if c.merged < 1 and count < 8 then return nil end
            io.stderr:write(string.format(
                "[TEST] %s: merged=%d preset=%d compose=%d\n",
                label, c.merged, c.preset, c.compose_screen))
            assert(c.merged >= 1,
                label .. ": should drive a merged screen solve")
            assert(c.preset == 0,
                label .. ": standalone preset solve should not fire")
            assert_clients_within_workarea(label)
            io.stderr:write(
                "[TEST] PASS: " .. label .. " joins the merged solve\n")
            return true
        end,
    }
end

local steps = {
    -- One tag, gap-free, four tiled clients reused across every layout.
    function()
        tag = screen.primary.tags[1]
        tag:view_only()
        tag.gap = 0
        tag.master_count = 1
        tag.master_width_factor = 0.5
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
}

local function add_steps(list)
    for _, s in ipairs(list) do steps[#steps + 1] = s end
end

-- Each newly merge-capable built-in layout.
add_steps(merged_layout_steps("clay.fair",            clay.fair))
add_steps(merged_layout_steps("clay.fair.horizontal", clay.fair.horizontal))
add_steps(merged_layout_steps("clay.spiral",          clay.spiral))
add_steps(merged_layout_steps("clay.spiral.dwindle",  clay.spiral.dwindle))
add_steps(merged_layout_steps("clay.corner.nw",       clay.corner.nw))
add_steps(merged_layout_steps("clay.max",             clay.max))

-- Prime Directive: an arbitrary user layout function still tiles, via the
-- non-merged path (no descriptor -> compose_screen returns merged=false ->
-- arrange writes p.geometries -> the apply loop in awful.layout positions
-- it). Every client gets the left third of the workarea.
local custom = {
    name = "custom_step3",
    arrange = function(p)
        for _, c in ipairs(p.clients) do
            p.geometries[c] = {
                x = p.workarea.x,
                y = p.workarea.y,
                width  = math.floor(p.workarea.width / 3),
                height = p.workarea.height,
            }
        end
    end,
}
add_steps({
    function()
        tag.layout = custom
        return true
    end,
    function(count)
        if count == 1 then
            _somewm_clay.reset_solve_counts()
            awful.layout.arrange(screen.primary)
            return nil
        end
        local c = counts()
        -- Wait for the non-merged arrange to actually run (compose_screen
        -- always solves the workarea even when it does not merge) so the
        -- merged==0 assertion below is meaningful, not vacuously true.
        if c.compose_screen < 1 and count < 8 then return nil end
        local first = tag:clients()[1]
        if not first then return nil end
        local g  = first:geometry()
        local wa = screen.primary.workarea
        local bw = first.border_width or 0
        -- The non-merged apply loop subtracts 2*bw (gap is 0) from the rect.
        local want_w = math.floor(wa.width / 3) - 2 * bw
        if math.abs(g.width - want_w) > 4 and count < 8 then return nil end
        io.stderr:write(string.format(
            "[TEST] custom: merged=%d compose=%d x=%d width=%d (want x~%d w~%d)\n",
            c.merged, c.compose_screen, g.x, g.width, wa.x, want_w))
        assert(c.merged == 0,
            "custom layout must NOT use the merged path")
        assert(math.abs(g.width - want_w) <= 4,
            "custom layout geometry should be applied (width ~ workarea/3)")
        assert(math.abs(g.x - wa.x) <= 2 + bw,
            "custom layout x should match the rect it wrote")
        io.stderr:write(
            "[TEST] PASS: custom user layout still tiles (escape hatch)\n")
        return true
    end,
})

-- max.fullscreen now folds into the merged solve: its "geometry" bounds make
-- compose_screen graft the subtree as a root-attached container spanning the
-- full screen, so it drives a merged solve (not the standalone preset) and the
-- clients cover screen.geometry rather than the workarea.
add_steps({
    function()
        tag.layout = clay.max.fullscreen
        return true
    end,
    function(count)
        if count == 1 then
            _somewm_clay.reset_solve_counts()
            awful.layout.arrange(screen.primary)
            return nil
        end
        local c = counts()
        if c.merged < 1 and count < 8 then return nil end
        io.stderr:write(string.format(
            "[TEST] max.fullscreen: merged=%d preset=%d\n", c.merged, c.preset))
        assert(c.merged >= 1,
            "max.fullscreen should now drive a merged screen solve")
        assert(c.preset == 0,
            "max.fullscreen standalone preset solve should not fire")
        local geo = screen.primary.geometry
        for _, cl in ipairs(tag:clients()) do
            local g  = cl:geometry()
            local bw = cl.border_width or 0
            utils.assert_geometry(g,
                { x = geo.x, y = geo.y, width = geo.width, height = geo.height },
                2 * bw + 4)
        end
        io.stderr:write(
            "[TEST] PASS: max.fullscreen joins the merged solve, covers screen.geometry\n")
        return true
    end,
})

-- Cleanup.
steps[#steps + 1] = function(count)
    if count == 1 then
        for _, c in ipairs(client.get()) do
            if c.valid then c:kill() end
        end
    end
    if #client.get() == 0 then return true end
    if count >= 10 then return true end
end

runner.run_steps(steps, { kill_clients = false })
