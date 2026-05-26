---------------------------------------------------------------------------
--- Test: wibar widgets paint from the merged solve, not the wibox forest.
--
-- Step 5 of the clay-tree conversion (retained-render). On a merge-capable
-- screen, an expressible wibar's widget boxes come from the one merged screen
-- solve; the per-container "wibox" solve forest no longer runs for it.
-- Verifies (1) a widget relayout drives a merged solve but fires zero wibox
-- solves, and (2) the widget still lands at the right on-screen box (the
-- placements-derived matrices are correct, so input hit-testing works).
---------------------------------------------------------------------------

local runner = require("_runner")
local test_client = require("_client")
local utils = require("_utils")
local awful = require("awful")
local wibox = require("wibox")

if not test_client.is_available() then
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local clay = require("awful.layout.clay")

local s = screen.primary
local tag = s.tags[1]
local tb_left, bar

local function counts() return _somewm_clay.get_solve_counts() end

local steps = {
    -- tile layout + an expressible wibar: align{ fixed{tb}, _, background{margin{tb}} }.
    -- Every container here implements :layout_node, so the whole tree is a node
    -- in the merged solve and the retained path covers it.
    function()
        tag:view_only()
        tag.layout = clay.tile
        tag.gap = 0

        tb_left = wibox.widget.textbox("L")
        local left  = wibox.layout.fixed.horizontal(tb_left)
        local right = wibox.container.background(
            wibox.container.margin(wibox.widget.textbox("R"), 2, 2, 2, 2))
        local root  = wibox.layout.align.horizontal(left, nil, right)
        bar = awful.wibar { position = "top", screen = s, height = 20, widget = root }
        return true
    end,

    -- A tiled client, so the screen actually merges (source="merged").
    function(count)
        if count == 1 then test_client("retained_widgets") end
        return utils.find_client_by_class("retained_widgets") and true or nil
    end,

    -- Wait for the first draw (hierarchy built) AND the merged solve to record
    -- the wibar root in the placements map. Until then a relayout would fall
    -- back to the forest, so the retained path isn't exercisable yet.
    function(count)
        awful.layout.arrange(s)
        local top = bar._drawable and bar._drawable._widget
        if bar._drawable and bar._drawable._widget_hierarchy
            and s._clay_widget_placements and top
            and s._clay_widget_placements[top] then
            return true
        end
        if count >= 30 then error("wibar never reached the retained path") end
        return nil
    end,

    -- A widget relayout: drives a merged solve, fires zero wibox solves.
    function(count)
        if count == 1 then
            _somewm_clay.reset_solve_counts()
            tb_left:set_text("a considerably longer label")
            return nil
        end
        local c = counts()
        -- Wait until the arrange has run (merged solve recorded) and the redraw
        -- that consumes its boxes has settled.
        if c.merged < 1 and count < 12 then return nil end
        if count < 4 then return nil end
        io.stderr:write(string.format(
            "[TEST] after widget relayout: merged=%d wibox=%d total=%d\n",
            c.merged, c.wibox, c.total))
        assert(c.merged >= 1,
            "an expressible wibar relayout should drive a merged screen solve")
        assert(c.wibox == 0,
            string.format("retained render should fire NO wibox forest solve, got %d",
                c.wibox))
        io.stderr:write("[TEST] PASS: wibar relaid out from the merged solve, forest stayed silent\n")
        return true
    end,

    -- The placements-derived matrices are correct: a point in the left slot
    -- hit-tests to the left textbox at the wibar's left edge.
    function()
        local found = bar._drawable:find_widgets(1, 10)
        local hit
        for _, e in ipairs(found) do
            if e.widget == tb_left then hit = e end
        end
        assert(hit, "left textbox should be hit-testable after a retained relayout")
        assert(hit.x <= 2 and hit.x >= -2,
            string.format("left textbox should sit at the wibar's left edge, x=%d", hit.x))
        assert(hit.height > 0 and hit.width > 0,
            "hit-tested textbox should have a non-empty box")
        io.stderr:write(string.format(
            "[TEST] PASS: left textbox hit-tests at x=%d w=%d h=%d\n",
            hit.x, hit.width, hit.height))
        return true
    end,

    -- Cleanup.
    function(count)
        if count == 1 then
            bar.visible = false
            for _, c in ipairs(client.get()) do
                if c.valid then c:kill() end
            end
        end
        if #client.get() == 0 then return true end
        if count >= 10 then
            for _, pid in ipairs(test_client.get_spawned_pids()) do
                os.execute("kill -9 " .. pid .. " 2>/dev/null")
            end
            return true
        end
    end,
}

runner.run_steps(steps, { kill_clients = false })
