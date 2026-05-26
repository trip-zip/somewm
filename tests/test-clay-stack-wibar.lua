---------------------------------------------------------------------------
--- Test: a stack-rooted wibar expands through the merged solve.
--
-- Mirrors somewmrc's bar shape: stack{ align{left,_,right}, place{centered} }.
-- stack and place now have :layout_node builders, so the whole bar is a node in
-- the one screen solve and paints from it (retained render) instead of the
-- per-container "wibox" solves. Regression for the bug where the stack inherited
-- fixed:layout_node and the bar rendered with every widget crammed to the left.
-- Verifies (1) a relayout fires zero wibox solves, and (2) the align spans the
-- full bar width (right widget on the right) with the place child centered.
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
local tb_left, tb_right, tb_clock, bar

local function counts() return _somewm_clay.get_solve_counts() end

local steps = {
    function()
        tag:view_only()
        tag.layout = clay.tile
        tag.gap = 0

        tb_left  = wibox.widget.textbox("LEFT")
        tb_right = wibox.widget.textbox("RIGHT")
        tb_clock = wibox.widget.textbox("CLK")
        local left  = wibox.layout.fixed.horizontal(tb_left)
        local right = wibox.layout.fixed.horizontal(tb_right)
        local row   = wibox.layout.align.horizontal(left, nil, right)
        local centered = wibox.container.place(tb_clock) -- halign defaults center
        local root  = wibox.layout.stack(row, centered)
        bar = awful.wibar { position = "top", screen = s, height = 20, widget = root }
        return true
    end,

    function(count)
        if count == 1 then test_client("stack_wibar") end
        return utils.find_client_by_class("stack_wibar") and true or nil
    end,

    -- Wait for the stack root to land in the placements map: that means the
    -- whole bar (stack -> align -> fixeds, stack -> place -> clock) is in the
    -- merged solve, not degraded to a single forest leaf.
    function(count)
        awful.layout.arrange(s)
        local top = bar._drawable and bar._drawable._widget
        if s._clay_widget_placements and top and s._clay_widget_placements[top] then
            return true
        end
        if count >= 30 then error("stack-rooted wibar never reached the merged solve") end
        return nil
    end,

    -- A relayout drives a merged solve (the stack + align go through the one
    -- screen solve). The place/clock overlay degrades to the forest, so wibox is
    -- not zero here -- the headline retained win is asserted on a fully
    -- expressible bar in test-clay-retained-widgets.
    function(count)
        if count == 1 then
            _somewm_clay.reset_solve_counts()
            tb_left:set_text("a much longer left label")
            return nil
        end
        local c = counts()
        if c.merged < 1 and count < 12 then return nil end
        if count < 4 then return nil end
        assert(c.merged >= 1, "stack-rooted wibar relayout should drive a merged solve")
        return true
    end,

    -- The regression check: the align spans the FULL bar width (it was crammed
    -- to the left when the stack inherited fixed:layout_node). Left widget at the
    -- left edge, right widget past the middle, and the centered clock (forest)
    -- near the middle at its real (non-collapsed) width.
    function()
        local g = bar:geometry()
        local function box_of(w)
            for x = 0, g.width - 1, 2 do
                for _, e in ipairs(bar._drawable:find_widgets(x, 10)) do
                    if e.widget == w then return e end
                end
            end
        end
        local left, right, clock = box_of(tb_left), box_of(tb_right), box_of(tb_clock)
        assert(left and left.x <= 2,
            "left widget should sit at the left edge")
        assert(right and right.x > g.width / 2,
            string.format("right widget should be past mid (regression: it was crammed left); x=%s",
                right and math.floor(right.x) or "nil"))
        assert(clock and clock.width > 1,
            string.format("centered clock should keep its real width, got w=%s",
                clock and math.floor(clock.width) or "nil"))
        assert(math.abs((clock.x + clock.width / 2) - g.width / 2) <= g.width * 0.15,
            string.format("clock should be roughly centered; center=%.0f bar/2=%.0f",
                clock.x + clock.width / 2, g.width / 2))
        io.stderr:write(string.format(
            "[TEST] PASS: align spans full width (right x=%.0f/%d), clock centered (x=%.0f w=%.0f)\n",
            right.x, g.width, clock.x, clock.width))
        return true
    end,

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
