---------------------------------------------------------------------------
--- Test: wibar widgets paint from the screen solve under a NON-merge layout.
--
-- Widgets phase (#44 + #45). Once the `_clay_merge_capable` gate is gone and the
-- widget -> arrange hooks are ungated, a screen-attached wibar reflects through
-- the one screen solve under *any* layout, not just merge-capable descriptors.
-- Under magnifier (a descriptor-less layout) this verifies (1) a widget relayout
-- drives a screen solve (the ungated hook, #45) and (2) fires zero wibox forest
-- solves (placements are always consumed, #44), and (3) the widget still lands at
-- the right on-screen box.
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
    -- A NON-merge layout (magnifier is descriptor-less) plus an expressible
    -- wibar: align{ fixed{tb}, _, background{margin{tb}} }.
    function()
        tag:view_only()
        tag.layout = clay.magnifier
        tag.gap = 0

        tb_left = wibox.widget.textbox("L")
        local left  = wibox.layout.fixed.horizontal(tb_left)
        local right = wibox.container.background(
            wibox.container.margin(wibox.widget.textbox("R"), 2, 2, 2, 2))
        local root  = wibox.layout.align.horizontal(left, nil, right)
        bar = awful.wibar { position = "top", screen = s, height = 20, widget = root }
        return true
    end,

    -- A client, so magnifier actually reflects geometries (a real non-merge solve).
    function(count)
        if count == 1 then test_client("nonmerge_widgets") end
        return utils.find_client_by_class("nonmerge_widgets") and true or nil
    end,

    -- Wait for the first draw AND the screen solve to record the wibar root in
    -- the placements map. Before #44 this map was never consumed under a
    -- non-merge layout; now it always is.
    function(count)
        awful.layout.arrange(s)
        local top = bar._drawable and bar._drawable._widget
        if bar._drawable and bar._drawable._widget_hierarchy
            and s._clay_widget_placements and top
            and s._clay_widget_placements[top] then
            return true
        end
        if count >= 30 then error("wibar never reached the screen-solve placements under magnifier") end
        return nil
    end,

    -- A widget relayout under the non-merge layout: drives a screen solve
    -- (compose_screen / merged source), fires zero wibox forest solves.
    function(count)
        if count == 1 then
            _somewm_clay.reset_solve_counts()
            tb_left:set_text("a considerably longer label")
            return nil
        end
        local c = counts()
        local screen_solves = c.merged + c.compose_screen
        if screen_solves < 1 and count < 12 then return nil end
        if count < 4 then return nil end
        io.stderr:write(string.format(
            "[TEST] non-merge widget relayout: merged=%d compose_screen=%d wibox=%d\n",
            c.merged, c.compose_screen, c.wibox))
        assert(screen_solves >= 1,
            "a wibar relayout under a non-merge layout should drive a screen solve (ungated hook)")
        assert(c.wibox == 0,
            string.format("non-merge retained render should fire NO wibox forest solve, got %d",
                c.wibox))
        io.stderr:write("[TEST] PASS: non-merge wibar relaid out from the screen solve, forest stayed silent\n")
        return true
    end,

    -- The placements-derived matrices are correct: the left textbox hit-tests at
    -- the wibar's left edge.
    function()
        local found = bar._drawable:find_widgets(1, 10)
        local hit
        for _, e in ipairs(found) do
            if e.widget == tb_left then hit = e end
        end
        assert(hit, "left textbox should be hit-testable under a non-merge layout")
        assert(hit.x <= 2 and hit.x >= -2,
            string.format("left textbox should sit at the wibar's left edge, x=%d", hit.x))
        assert(hit.width > 0 and hit.height > 0,
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
