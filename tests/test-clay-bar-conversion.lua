---------------------------------------------------------------------------
-- Test: the dump says which bars convert and why the rest do not
--
-- The tree dump is the oracle for the conversion work: a bar that quietly
-- stops converting still draws the same pixels, so nothing else catches it.
-- Each bar here is a shape a real config takes, and the assertions are what
-- the dump has to keep answering: a converted bar names every container it
-- solved, including the ones that emit no render command at all, and a bar
-- that paints itself whole names the reason it does.
--
-- Run: make test-one TEST=tests/test-clay-bar-conversion.lua
---------------------------------------------------------------------------

local runner = require("_runner")
local capture = require("_widget_capture")
local wibox = require("wibox")
local gshape = require("gears.shape")

local s = screen[1]
local leaf_widget = capture.leaf_widget

local bars = {}

local function lines()
    local out = {}
    for line in awesome._clay_tree(s):gmatch("[^\n]+") do
        out[#out + 1] = line
    end
    return out
end

-- Every render command's element id. A converted container that paints
-- nothing is in the tree and in none of these, which is the whole reason the
-- dump walks the tree and not this list.
local function command_ids()
    local ids = {}
    for _, line in ipairs(lines()) do
        local id = line:match("^  (%x+) %u")
        if id then
            ids[id] = true
        end
    end
    return ids
end

-- The dump block for a bar: the drawin line, and the tree nodes under it.
local function block(bar)
    local d = bar.drawin
    -- The drawin's own line, not the command line that draws it: a whole
    -- drawin's image leaf names itself the same way.
    local want = string.format("  drawin screen %d %dx%d+%d+%d ", s.index,
        d.width, d.height, d.x, d.y)
    local head, nodes = nil, {}

    for _, line in ipairs(lines()) do
        if head then
            local id, indent, class = line:match("^    (%x+) ( *)([%w_.-]+)")
            if not id then
                break
            end
            nodes[#nodes + 1] = {
                id = id, depth = #indent / 2, class = class, line = line,
            }
        elseif line:sub(1, #want) == want then
            head = line
        end
    end
    return head, nodes
end

local function node_named(nodes, class)
    for _, node in ipairs(nodes) do
        if node.class == class then
            return node
        end
    end
    return nil
end

-- A bar of its own geometry, so its block in the dump is unambiguous.
local function new_bar(args)
    local y = 40 * #bars
    local bar = wibox {
        x = 0, y = y, width = 400, height = 24, screen = s,
        bg = "#101010", visible = true,
        opacity = args.opacity,
    }

    bars[#bars + 1] = bar
    bar:setup(args.widget or {
        layout = wibox.layout.stack,
        {
            layout = wibox.layout.align.horizontal,
            {
                layout = wibox.layout.fixed.horizontal,
                leaf_widget(40, nil, "#ff0000"),
                leaf_widget(60, nil, "#00ff00"),
            },
            { widget = wibox.container.background },
            {
                layout = wibox.layout.fixed.horizontal,
                leaf_widget(30, nil, "#0000ff"),
            },
        },
        {
            {
                { leaf_widget(70, 16, "#00ffff"), margins = 4,
                    widget = wibox.container.margin },
                bg = "#204080",
                widget = wibox.container.background,
            },
            halign = "center",
            widget = wibox.container.place,
        },
    })
    if args.shape then
        bar.shape = args.shape
    end
    return bar
end

-- Build a bar, wait for it to reach the dump, then run `check` on its block.
local function bar_step(args, check)
    local bar

    return function(count)
        if count == 1 then
            bar = new_bar(args)
            return nil
        end

        local head, nodes = block(bar)

        if not head then
            assert(count < 20, args.what .. ": never reached the dump")
            return nil
        end
        -- A converted bar reaches the dump one frame before its tree is
        -- declared, so the boxes are not readable yet.
        if head:find("converted", 1, true) and #nodes == 0 then
            assert(count < 20, args.what .. ": never declared its tree")
            return nil
        end
        check(head, nodes, bar)
        io.stderr:write("[PASS] " .. args.what .. "\n")
        bar.visible = false
        return true
    end
end

local steps = {
    -- The bundled bar's shape, unshaped: a stack of an align of two fixed
    -- layouts and a background, over a centered place.
    bar_step({ what = "an unshaped bar converts, containers and all" },
        function(head, nodes, bar)
            assert(head:find("converted", 1, true),
                "the bar did not convert: " .. head)

            for _, class in ipairs({
                "drawable",
                "wibox.layout.stack",
                "wibox.layout.align",
                "wibox.layout.fixed",
                "wibox.container.place",
                "wibox.container.background",
                "wibox.container.margin",
            }) do
                assert(node_named(nodes, class),
                    "no " .. class .. " in the solved tree")
            end

            -- Every leaf widget is a raster, and nothing else is.
            local rasters = 0
            for _, node in ipairs(nodes) do
                if node.line:find(" raster ", 1, true) then
                    rasters = rasters + 1
                end
            end
            assert(rasters == 4,
                "expected four raster leaves, got " .. rasters)

            -- The readback agrees with the dump about how much was solved.
            local boxes = awesome._test_widget_boxes(bar.drawin)
            assert(#boxes >= 12,
                "only " .. #boxes .. " solved boxes, expected at least 12")

            -- The point of walking the tree: align paints nothing, so Clay
            -- emits no command for it, and only the tree can show it.
            local align = node_named(nodes, "wibox.layout.align")
            assert(align.line:find("box %d+,%d+ %d+x%d+"),
                "the align has no solved box: " .. align.line)
            assert(not command_ids()[align.id],
                "the align was expected to emit no render command")
        end),

    -- The shape every bundled theme sets through beautiful.wibar_shape. The
    -- masks are applied to the drawable's own pixels, so the whole drawin
    -- paints itself. Step 5 of the conversion plan changes this, and has to
    -- change this test with it.
    bar_step({
        what = "a shaped bar paints whole, and says which masks",
        shape = function(cr, w, h) gshape.rounded_rect(cr, w, h, 8) end,
    }, function(head)
        assert(head:find("whole:", 1, true), "the shaped bar converted")
        assert(head:find("shape_bounding", 1, true)
            and head:find("shape_clip", 1, true),
            "the masks are not named: " .. head)
    end),

    -- A translucent drawin blends once as one layer.
    bar_step({ what = "a translucent bar paints whole", opacity = 0.5 },
        function(head)
            assert(head:find("whole:", 1, true),
                "the translucent bar converted")
            assert(head:find("opacity", 1, true),
                "the opacity is not named: " .. head)
        end),

    -- The legacy tray host (awesome.systray), which composites into the
    -- drawable's own pixels. Nothing in lua/ calls it; a config still can.
    bar_step({ what = "a legacy systray host paints whole" },
        function(head, _, bar)
            -- Taking the tray drops the tree there and then, so the dump
            -- says so without waiting for a redraw.
            awesome.systray(bar.drawin, 0, 0, 16, true)

            local hosted = block(bar)

            assert(hosted:find("whole:", 1, true)
                and hosted:find("systray", 1, true),
                "the tray host is not named: " .. hosted)
            awesome.systray(bar.drawin)
        end),

    -- A tree past the per-drawin node cap is refused, not truncated, and
    -- not fatal: Clay's own capacity is what the budget is protecting.
    bar_step({
        what = "a tree past the node cap paints whole",
        widget = (function()
            local w = leaf_widget(10, 10, "#ff0000")
            for _ = 1, 1100 do
                w = { w, margins = 0, widget = wibox.container.margin }
            end
            return w
        end)(),
    }, function(head)
        assert(head:find("whole:", 1, true), "the oversized tree converted")
        assert(head:find("budget", 1, true),
            "the size is not named: " .. head)
    end),
}

runner.run_steps(steps)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
