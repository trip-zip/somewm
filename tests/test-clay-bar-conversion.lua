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
local awful = require("awful")
local wibox = require("wibox")
local gshape = require("gears.shape")

local s = screen[1]
local leaf_widget = capture.leaf_widget

local bars = {}
local budget_bars = {}
local tooltip

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
        bg = args.bg or "#101010", visible = true,
        opacity = args.opacity,
        border_width = args.border_width, border_color = args.border_color,
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
    if args.input_passthrough then bar.input_passthrough = true end
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

            -- Four described leaf widgets fill their solved boxes.
            local leaves = 0
            for _, node in ipairs(nodes) do
                if node.class == "leaf" then
                    leaves = leaves + 1
                end
            end
            assert(leaves == 4,
                "expected four leaves, got " .. leaves)

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

    -- A tree wider than its bar lays out at its own size and is cut at the
    -- bar's edge, never squeezed into it: the leaf after a long text sits
    -- past the edge, where the engine put it.
    bar_step({
        what = "an overflowing bar is cut, not squeezed",
        widget = {
            layout = wibox.layout.fixed.horizontal,
            wibox.widget.textbox(("wide "):rep(40)),
            leaf_widget(30, nil, "#ff0000"),
        },
    }, function(head, nodes, bar)
        assert(head:find("converted", 1, true), "the bar painted whole: " .. head)

        local boxes = awesome._test_widget_boxes(bar.drawin)
        local text, leaf = boxes[3], boxes[4]

        assert(text.width > bar.width, string.format(
            "the text was squeezed to %d in a bar of %d", text.width, bar.width))
        assert(leaf.x == text.width and leaf.width == 30, string.format(
            "the leaf sits at %d+%d, want %d+30", leaf.x, leaf.width, text.width))
        assert(#nodes == 5, #nodes .. " nodes, expected 5: the text is one line")
    end),

    -- A transparent bar converts: its root draws nothing and still takes
    -- input over its whole box, as a wibox does, so the pointer over a gap
    -- beside the leaf is the bar's. An awful.tooltip is such a wibox, its
    -- background drawn by a container inside; it converts with it.
    function(count)
        local bar = bars[#bars]

        if count == 1 then
            bar = new_bar({
                bg = "#00000000",
                widget = { leaf_widget(40, nil, "#ff0000"), left = 16,
                    widget = wibox.container.margin },
            })
            tooltip = awful.tooltip { objects = { bar }, text = "a tip" }
            tooltip.visible = true
            return nil
        end

        local head = block(bar)
        local tip = block(tooltip.wibox)

        if not (head and tip) then
            assert(count < 20, "the transparent bar or its tooltip never reached the dump")
            return nil
        end
        assert(head:find("converted", 1, true), "the transparent bar painted whole: " .. head)
        assert(tip:find("converted", 1, true), "the tooltip painted whole: " .. tip)

        mouse.coords({ x = bar.x + 4, y = bar.y + 4 })
        mouse.coords({ x = bar.x + 4, y = bar.y + 4 })
        assert(mouse.object_under_pointer() == bar.drawin,
            "the pointer over the transparent gap is not the bar's")
        mouse.coords({ x = 100, y = 100 })
        tooltip.visible = false
        bar.visible = false
        io.stderr:write("[PASS] a transparent bar converts and takes input\n")
        return true
    end,

    bar_step({
        what = "a pass-through bar converts and takes no input",
        bg = "#00000000", input_passthrough = true,
        widget = { leaf_widget(40, nil, "#ff0000"), left = 16,
            widget = wibox.container.margin },
    }, function(head, _, bar)
        assert(head:find("converted", 1, true), head)
        mouse.coords({ x = bar.x + 4, y = bar.y + 4 })
        mouse.coords({ x = bar.x + 4, y = bar.y + 4 })
        assert(mouse.object_under_pointer() ~= bar.drawin,
            "the pass-through bar took input")
        mouse.coords({ x = 100, y = 100 })
    end),

    -- The shape every bundled theme sets through beautiful.wibar_shape: a
    -- rounded rectangle, which the root element says as its corner radius.
    -- The corner pixel outside the arc is not the bar's.
    bar_step({
        what = "a rounded bar converts, with its radius",
        shape = function(cr, w, h) gshape.rounded_rect(cr, w, h, 8) end,
        -- Nothing but the bar's own background in its top left corner.
        widget = { leaf_widget(40, nil, "#ff0000"), left = 16,
            widget = wibox.container.margin },
    }, function(head, _, bar)
        assert(head:find("converted", 1, true), "the rounded bar painted whole: " .. head)
        assert(head:find("radius 8", 1, true), "the radius is not named: " .. head)

        local cap = capture.new(s, bar.x, bar.y, bar.width, bar.height)
        local shot = cap:shot()
        local r, g, b = cap:pixel(shot, 1, 1)

        assert(not (r == 0x10 and g == 0x10 and b == 0x10),
            "the corner outside the arc shows the bar")
        cap:assert_pixel(shot, 12, 12, "#101010", "inside the arc")
    end),

    bar_step({
        what = "a bordered rounded bar converts with its content radius",
        border_width = 2, border_color = "#ff8800",
        shape = function(cr, w, h) gshape.rounded_rect(cr, w, h, 8) end,
        widget = { leaf_widget(40, nil, "#ff0000"), left = 16,
            widget = wibox.container.margin },
    }, function(head, _, bar)
        assert(head:find("converted", 1, true) and head:find("radius 6", 1, true), head)
        local cap = capture.new(s, bar.x, bar.y, bar.width, bar.height)
        local shot = cap:shot()
        cap:assert_pixel(shot, 12, 12, "#101010", "inside the arc")
        local r, g, b = cap:pixel(shot, 1, 1)
        assert(not (r == 0x10 and g == 0x10 and b == 0x10), "the corner shows the bar")
        for _, offset in ipairs { 1, 12 } do
            mouse.coords({ x = bar.x + offset, y = bar.y + offset })
            mouse.coords({ x = bar.x + offset, y = bar.y + offset })
            assert((mouse.object_under_pointer() == bar.drawin) == (offset == 12),
                offset == 12 and "inside the arc is not the bar"
                    or "the corner outside the arc takes the bar's input")
        end
        mouse.coords({ x = 100, y = 100 })
    end),

    -- A leaf drawn into the corner is cut to the arc.
    bar_step({
        what = "a leaf in a rounded corner is cut to the arc",
        shape = function(cr, w, h) gshape.rounded_rect(cr, w, h, 8) end,
    }, function(head, _, bar)
        assert(head:find("radius 8", 1, true), "the radius is not named: " .. head)

        local cap = capture.new(s, bar.x, bar.y, bar.width, bar.height)
        local shot = cap:shot()
        local r, g, b = cap:pixel(shot, 1, 1)

        assert(not (r > 0xc0 and g < 0x40 and b < 0x40),
            "the leaf shows past the arc")
        cap:assert_pixel(shot, 12, 12, "#ff0000", "the leaf inside the arc")

        -- And takes no input past the arc: the corner falls through to
        -- whatever is behind the bar, as the mask let it. Warped twice,
        -- since the hit test runs against the position before the move.
        mouse.coords({ x = bar.x + 1, y = bar.y + 1 })
        mouse.coords({ x = bar.x + 1, y = bar.y + 1 })
        assert(mouse.object_under_pointer() ~= bar.drawin,
            "the corner outside the arc takes the bar's input")
        mouse.coords({ x = bar.x + 12, y = bar.y + 12 })
        mouse.coords({ x = bar.x + 12, y = bar.y + 12 })
        assert(mouse.object_under_pointer() == bar.drawin,
            "inside the arc is not the bar")
        mouse.coords({ x = 100, y = 100 })
    end),

    bar_step({ what = "a bar of another shape converts unshaped", shape = gshape.hexagon },
        function(head)
            assert(head:find("converted", 1, true) and not head:find("whole:", 1, true), head)
        end),

    bar_step({ what = "a translucent bar converts", opacity = 0.5 },
        function(head, _, bar)
            assert(head:find("converted", 1, true), "the translucent bar painted whole: " .. head)
            local cap = capture.new(s, bar.x, bar.y, bar.width, bar.height)
            local r = cap:pixel(cap:shot(), 20, 12)
            assert(r < 0xd0, "the translucent leaf did not blend")
        end),

    bar_step({
        what = "a tree past the node cap shows nothing", bg = "#123456",
        widget = (function()
            local w = leaf_widget(10, 10, "#ff0000")
            for _ = 1, 1100 do
                w = { w, margins = 0, widget = wibox.container.margin }
            end
            return w
        end)(),
    }, function(head, _, bar)
        assert(head:find("nothing:", 1, true), "the oversized tree converted")
        assert(head:find("budget", 1, true),
            "the size is not named: " .. head)
        local cap = capture.new(s, bar.x, bar.y, bar.width, bar.height)
        local r, g, b = cap:pixel(cap:shot(), 5, 5)
        assert(not (r == 0x12 and g == 0x34 and b == 0x56), "stale bar pixels remain")
    end),
    function(count)
        if count == 1 then
            for i = 1, 8 do
                local w = leaf_widget(10, 10, "#ff0000")

                for _ = 1, 900 do
                    w = { w, margins = 0,
                        widget = wibox.container.margin }
                end
                budget_bars[i] = wibox {
                    x = 0, y = 200 + i, width = 40, height = 8,
                    screen = s, bg = "#101010", visible = true,
                }
                budget_bars[i]:setup(w)
            end
            return nil
        end

        local converted, refused = 0, 0

        for _, bar in ipairs(budget_bars) do
            local head = block(bar)

            if not head then
                assert(count < 30, "a budget bar never reached the dump")
                return nil
            end
            if head:find("converted", 1, true) then
                converted = converted + 1
            elseif head:find("budget", 1, true) then
                refused = refused + 1
            end
        end
        assert(converted + refused == #budget_bars, string.format(
            "%d converted and %d refused, of %d bars",
            converted, refused, #budget_bars))
        assert(refused > 0, "no bar was held back by the shared budget")
        assert(converted > 0, "the shared budget refused every bar")
        io.stderr:write(string.format(
            "[PASS] the shared budget holds: %d bars converted, %d show nothing\n",
            converted, refused))
        for _, bar in ipairs(budget_bars) do
            bar.visible = false
        end
        return true
    end,
}

runner.run_steps(steps)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
