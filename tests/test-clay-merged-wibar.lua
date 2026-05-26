---------------------------------------------------------------------------
--- Test: wibar widgets are nodes in the merged screen solve.
--
-- Step 2 of the clay-tree conversion. On a merge-capable (tile) screen, a
-- wibar's widgets are grafted into the one screen solve as real nodes.
-- Verifies (1) clients still tile correctly with a widgeted wibar present,
-- and (2) a widget layout change drives a merged screen solve
-- (begin_layout source="merged").
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

local steps = {
    -- tile layout + a wibar exercising align / fixed / margin / background.
    function()
        tag:view_only()
        tag.layout = clay.tile
        tag.master_width_factor = 0.5
        tag.master_count = 1
        tag.gap = 0

        tb_left = wibox.widget.textbox("L")
        local left  = wibox.layout.fixed.horizontal(tb_left)
        local right = wibox.container.background(
            wibox.container.margin(wibox.widget.textbox("R"), 2, 2, 2, 2))
        local root  = wibox.layout.align.horizontal(left, nil, right)
        bar = awful.wibar { position = "top", screen = s, height = 20, widget = root }
        io.stderr:write("[TEST] Set clay.tile + created widgeted wibar\n")
        return true
    end,

    -- Wait for the wibar's first draw: the hierarchy is built and the widgets
    -- are connected, which the layout-change trigger depends on.
    function(count)
        if bar._drawable._widget_hierarchy then return true end
        if count >= 20 then error("wibar never drew its hierarchy") end
        return nil
    end,

    -- Spawn a client.
    function(count)
        if count == 1 then test_client("merged_wibar") end
        return utils.find_client_by_class("merged_wibar") and true or nil
    end,

    -- Regression: the single client tiles inside the workarea, below the bar.
    function(count)
        if count == 1 then
            awful.layout.arrange(s)
            return nil
        end
        local c = utils.find_client_by_class("merged_wibar")
        if not c then return nil end
        local wa = s.workarea
        local g = c:geometry()
        local bw = c.border_width or 0
        local tol = 2 * bw + 4
        io.stderr:write(string.format(
            "[TEST] client x=%d y=%d w=%d h=%d / workarea x=%d y=%d w=%d h=%d\n",
            g.x, g.y, g.width, g.height, wa.x, wa.y, wa.width, wa.height))
        assert(wa.height < s.geometry.height,
            "workarea should be shorter than the screen (wibar reserves space)")
        assert(g.y >= wa.y - tol,
            string.format("client y=%d should sit at/below workarea y=%d", g.y, wa.y))
        assert(g.y + g.height <= wa.y + wa.height + tol,
            "client should fit within the workarea height")
        assert(math.abs(g.width - wa.width) <= wa.width * 0.05 + tol,
            string.format("client width=%d should ~fill workarea width=%d",
                g.width, wa.width))
        io.stderr:write("[TEST] PASS: client tiles with a widgeted wibar present\n")
        return true
    end,

    -- New behavior: a widget layout change drives a merged screen solve.
    function(count)
        if count == 1 then
            _somewm_clay.reset_solve_counts()
            tb_left:set_text("a considerably longer label")
            return nil
        end
        local c = _somewm_clay.get_solve_counts()
        if c.merged < 1 and count < 8 then return nil end
        io.stderr:write(string.format(
            "[TEST] after widget change: merged=%d total=%d\n", c.merged, c.total))
        assert(c.merged >= 1,
            "a widget layout_changed on a merged wibar should drive a merged solve")
        io.stderr:write("[TEST] PASS: widget change drove a merged screen solve\n")
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
