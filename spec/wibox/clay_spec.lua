---------------------------------------------------------------------------
-- Tests for wibox.clay, the widget-tree-to-Clay compile step.
---------------------------------------------------------------------------

local gcolor = require("gears.color")
local gshape = require("gears.shape")
local hierarchy = require("wibox.hierarchy")
local background = require("wibox.container.background")
local margin = require("wibox.container.margin")
local constraint = require("wibox.container.constraint")
local utils = require("wibox.test_utils")
local wclay = require("wibox.clay")

local BG = gcolor("#102030")
local BG_RGBA = { 0x10/255, 0x20/255, 0x30/255, 1 }
local context = { dpi = 96 }

-- A widget the tree can never convert, so it always ends up on a leaf.
local function leaf_widget()
    return utils.widget_stub(10, 10)
end

-- compile() walks the laid-out tree, so lay one out. hierarchy.new updates
-- synchronously, which is all this needs: no drawable, no drawin, no screen.
local function compile(bg, root, fg)
    local drawable = {
        background_color = bg,
        foreground_color = fg,
        background_image = nil,
    }
    local h = root and hierarchy.new(context, root, 100, 100,
        function() end, function() end, {})

    return wclay.compile(drawable, h, context)
end

-- The node for a widget put under a converted margin, so a widget that
-- degrades shows up as the margin's raster leaf instead of a nil tree.
local function layout_node(w)
    local tree = compile(BG, margin(w, 1, 1, 1, 1), BG)

    return tree.children[1].children[1]
end

local function degraded(w)
    return layout_node(w).raster == true
end

-- The tree's nodes, outermost first, following the only child down: what
-- the stage 5 chain was, for trees that are still one.
local function chain(tree)
    local nodes = {}

    while tree do
        nodes[#nodes + 1] = tree
        tree = tree.children and tree.children[1]
    end
    return nodes
end

describe("wibox.clay", function()
    it("refuses a drawable whose own background is not a solid color", function()
        assert.is_nil(compile(nil, margin(leaf_widget(), 1, 1, 1, 1), BG))
        assert.is_nil(compile(
            gcolor("linear:0,0:10,0:0,#000000:1,#ffffff"),
            margin(leaf_widget(), 1, 1, 1, 1), BG))
        assert.is_nil(compile(gcolor("#00000000"),
            margin(leaf_widget(), 1, 1, 1, 1), BG))
    end)

    it("refuses a drawable with a background image", function()
        local h = hierarchy.new(context, margin(leaf_widget(), 1, 1, 1, 1),
            100, 100, function() end, function() end, {})

        assert.is_nil(wclay.compile({
            background_color = BG,
            foreground_color = BG,
            background_image = "anything",
        }, h, context))
    end)

    it("refuses a tree whose root converts nothing", function()
        assert.is_nil(compile(BG, leaf_widget(), BG))
        assert.is_nil(compile(BG, nil, BG))
    end)

    it("maps margins onto padding", function()
        local w = leaf_widget()
        local tree, leaves = compile(BG, margin(w, 1, 2, 3, 4), BG)
        local nodes = chain(tree)

        assert.is_equal(3, #nodes)
        assert.is_same(BG_RGBA, nodes[1].bg)
        assert.is_same({ 1, 2, 3, 4 }, nodes[2].pad)
        assert.is_nil(nodes[2].border)
        assert.is_true(nodes[3].raster)
        assert.is_equal(1, #leaves)
        assert.is_equal(w, leaves[1].hierarchy:get_widget())
        assert.is_equal(BG, leaves[1].fg)
    end)

    it("maps a margin color onto a border of the same widths", function()
        local nodes = chain(compile(BG,
            margin(leaf_widget(), 1, 2, 3, 4, "#ff0000"), BG))

        assert.is_same({ 1, 2, 3, 4 }, nodes[2].pad)
        assert.is_same({ 1, 2, 3, 4 }, nodes[2].bw)
        assert.is_same({ 1, 0, 0, 1 }, nodes[2].border)
    end)

    it("maps a background color and a square border", function()
        local w = background(leaf_widget(), "#00ff00")

        w.border_width = 2
        w.border_color = "#0000ff"

        local nodes = chain(compile(BG, w, BG))

        assert.is_same({ 0, 1, 0, 1 }, nodes[2].bg)
        assert.is_same({ 0, 0, 1, 1 }, nodes[2].border)
        assert.is_same({ 2, 2, 2, 2 }, nodes[2].bw)
        assert.is_equal(0, nodes[2].radius)
        assert.is_nil(nodes[2].pad)
    end)

    it("pads a background whose border strategy shrinks its child", function()
        local w = background(leaf_widget(), "#00ff00")

        w.border_width = 2
        w.border_color = "#0000ff"
        w.border_strategy = "inner"

        local nodes = chain(compile(BG, w, BG))

        assert.is_same({ 2, 2, 2, 2 }, nodes[2].pad)
    end)

    it("maps a rounded rectangle onto a corner radius the leaf shares", function()
        local tree = compile(BG,
            background(leaf_widget(), "#00ff00", function(cr, cw, ch)
                return gshape.rounded_rect(cr, cw, ch)
            end), BG)

        -- An inline shape function is not gears.shape.rounded_rect, so it
        -- draws itself: nothing above the leaf converted.
        assert.is_nil(tree)

        local w = background(leaf_widget(), "#00ff00")

        w:set_shape(gshape.rounded_rect, 8)

        local nodes = chain(compile(BG, w, BG))

        assert.is_equal(8, nodes[2].radius)
        assert.is_equal(8, nodes[3].radius)
        assert.is_true(nodes[3].raster)
    end)

    it("carries a rounded background's radius to a leaf under a margin", function()
        local w = background(leaf_widget(), "#00ff00")

        w:set_shape(gshape.rounded_rect, 8)

        local tree, leaves = compile(BG, margin(w, 5, 5, 5, 5), BG)
        local nodes = chain(tree)

        -- The margin converts, and so does the rounded background under it:
        -- its leaf sits at the same box, so the leaf's corners are its clip.
        assert.is_equal(4, #nodes)
        assert.is_same({ 5, 5, 5, 5 }, nodes[2].pad)
        assert.is_equal(8, nodes[3].radius)
        assert.is_true(nodes[4].raster)
        assert.is_equal(8, nodes[4].radius)
        assert.is_equal(1, #leaves)
        assert.is_equal(w, leaves[1].parent:get_widget())
    end)

    it("keeps a rounded background whole when its child converts", function()
        local inner = margin(leaf_widget(), 2, 2, 2, 2)
        local w = background(inner, "#00ff00")

        w:set_shape(gshape.rounded_rect, 8)

        local tree, leaves = compile(BG, w, BG)

        -- The background converts as a class, but its child would be a
        -- converted margin under a rounded corner: nothing converts, and the
        -- leaf the margin's subtree produced is gone with it.
        assert.is_nil(tree)
        assert.is_nil(leaves)
    end)

    it("refuses a rounded background that also has a border", function()
        local w = background(leaf_widget(), "#00ff00")

        w:set_shape(gshape.rounded_rect, 8)
        w.border_width = 1
        w.border_color = "#0000ff"

        assert.is_nil(compile(BG, w, BG))
    end)

    it("converts containers down to the first it cannot", function()
        local w = leaf_widget()
        local stopper = constraint(margin(w, 2, 2, 2, 2))
        local tree, leaves = compile(BG,
            background(margin(stopper, 4, 4, 4, 4), "#00ff00"), BG)
        local nodes = chain(tree)

        -- background, margin, then the constraint is the leaf; the margin
        -- inside it stays on the leaf with everything below.
        assert.is_equal(4, #nodes)
        assert.is_same({ 0, 1, 0, 1 }, nodes[2].bg)
        assert.is_same({ 4, 4, 4, 4 }, nodes[3].pad)
        assert.is_true(nodes[4].raster)
        assert.is_equal(stopper, leaves[1].hierarchy:get_widget())
        assert.is_equal(4, leaves[1].parent:get_widget().left)
    end)

    it("carries the innermost background foreground to the leaf", function()
        local fg = gcolor("#ff00ff")
        local w = background(leaf_widget(), "#00ff00")

        w.fg = fg

        local _, leaves = compile(BG, w, BG)

        assert.is_equal(fg, leaves[1].fg)
    end)

    it("stops at a widget whose drawing the tree does not carry", function()
        for prop, value in pairs {
            visible = false, opacity = 0.5, forced_width = 20, forced_height = 20,
        } do
            local w = margin(leaf_widget(), 3, 3, 3, 3)

            w[prop] = value
            assert.is_nil(compile(BG, w, BG), prop)
        end
    end)

    it("stops at a subclass that overrides the layout it converted", function()
        local w = margin(leaf_widget(), 3, 3, 3, 3)

        rawset(w, "layout", function() return {} end)
        assert.is_nil(compile(BG, w, BG))
    end)

    it("stops at a margin that shrinks away with its child", function()
        local w = margin(leaf_widget(), 3, 3, 3, 3)

        w.draw_empty = false
        assert.is_nil(compile(BG, w, BG))
    end)
end)

describe("wibox.clay fixed", function()
    local fixed = require("wibox.layout.fixed")


    it("maps direction and spacing, children fixed at their fit along it", function()
        local l = fixed.horizontal(utils.widget_stub(10, 5), utils.widget_stub(20, 5))

        l.spacing = 4

        local node = layout_node(l)

        assert.is_equal("x", node.dir)
        assert.is_equal(4, node.gap)
        assert.is_equal(2, #node.children)
        assert.is_equal(10, node.children[1].w)
        assert.is_nil(node.children[1].h)
        assert.is_equal(20, node.children[2].w)
        assert.is_true(node.children[2].raster)

        local v = layout_node(fixed.vertical(utils.widget_stub(5, 10)))

        assert.is_equal("y", v.dir)
        assert.is_equal(10, v.children[1].h)
        assert.is_nil(v.children[1].w)
    end)

    it("grows the last child when fill_space is set", function()
        local l = fixed.horizontal(utils.widget_stub(10, 5), utils.widget_stub(20, 5))

        l:fill_space(true)

        local node = layout_node(l)

        assert.is_equal(10, node.children[1].w)
        assert.is_nil(node.children[2].w)
    end)

    it("bounds each child's fit by what the ones before it left", function()
        -- 98 wide inside the margin: the second child is clamped to what is
        -- left, and the third starts past the edge, so the engine never
        -- placed it.
        local l = fixed.horizontal(utils.widget_stub(60, 5),
            utils.widget_stub(60, 5), utils.widget_stub(60, 5))
        local node = layout_node(l)

        assert.is_equal(2, #node.children)
        assert.is_equal(60, node.children[1].w)
        assert.is_equal(38, node.children[2].w)
    end)

    it("leaves out a child whose fit is zero along the direction", function()
        local hidden = utils.widget_stub(10, 5)

        hidden._private.visible = false

        local l = fixed.horizontal(utils.widget_stub(10, 5), hidden,
            utils.widget_stub(0, 5), utils.widget_stub(20, 5))
        local node = layout_node(l)

        assert.is_equal(2, #node.children)
        assert.is_equal(20, node.children[2].w)
    end)

    it("degrades for a spacing widget, negative spacing and overrides", function()
        local l = fixed.horizontal(utils.widget_stub(10, 5), utils.widget_stub(10, 5))

        l.spacing = 3
        l.spacing_widget = utils.widget_stub(3, 5)
        assert.is_true(degraded(l))

        l = fixed.horizontal(utils.widget_stub(10, 5), utils.widget_stub(10, 5))
        l.spacing = -2
        assert.is_true(degraded(l))

        l = fixed.horizontal(utils.widget_stub(10, 5))
        rawset(l, "layout", function(self, ...) return fixed.layout(self, ...) end)
        assert.is_true(degraded(l))

        l = fixed.horizontal(utils.widget_stub(10, 5))
        rawset(l, "fit", function(self, ...) return fixed.fit(self, ...) end)
        assert.is_true(degraded(l))
    end)
end)

describe("wibox.clay flex", function()
    local flex = require("wibox.layout.flex")


    it("grows every child along the direction, with max_widget_size as the ceiling", function()
        local l = flex.horizontal(utils.widget_stub(10, 5), utils.widget_stub(50, 5))

        l.spacing = 2

        local node = layout_node(l)

        assert.is_equal("x", node.dir)
        assert.is_equal(2, node.gap)
        assert.is_equal(2, #node.children)
        assert.is_nil(node.children[1].w)
        assert.is_nil(node.children[1].wmax)
        assert.is_true(node.children[2].raster)

        l.max_widget_size = 30
        node = layout_node(l)
        assert.is_equal(30, node.children[1].wmax)
        assert.is_equal(30, node.children[2].wmax)
        assert.is_nil(node.children[2].hmax)

        local v = flex.vertical(utils.widget_stub(5, 10))

        v.max_widget_size = 12
        node = layout_node(v)
        assert.is_equal("y", node.dir)
        assert.is_equal(12, node.children[1].hmax)
    end)

    it("degrades for a spacing widget, negative spacing and overrides", function()
        local l = flex.horizontal(utils.widget_stub(10, 5), utils.widget_stub(10, 5))

        l.spacing = 3
        l.spacing_widget = utils.widget_stub(3, 5)
        assert.is_true(degraded(l))

        l = flex.horizontal(utils.widget_stub(10, 5), utils.widget_stub(10, 5))
        l.spacing = -2
        assert.is_true(degraded(l))

        l = flex.horizontal(utils.widget_stub(10, 5))
        rawset(l, "layout", function(self, ...) return flex.layout(self, ...) end)
        assert.is_true(degraded(l))
    end)
end)

describe("wibox.clay align", function()
    local align = require("wibox.layout.align")

    -- 98 wide inside the margin.

    local function stub(w)
        return utils.widget_stub(w, 5)
    end

    it("inside: outer widgets at their fit, the second grows between", function()
        local node = layout_node(align.horizontal(stub(10), stub(200), stub(20)))

        assert.is_equal("x", node.dir)
        assert.is_equal(3, #node.children)
        assert.is_equal(10, node.children[1].w)
        assert.is_nil(node.children[2].w)
        assert.is_equal(20, node.children[3].w)
        for _, child in ipairs(node.children) do
            assert.is_true(child.raster)
            assert.is_nil(child.h)
        end

        local v = layout_node(align.vertical(utils.widget_stub(5, 10), stub(5), nil))

        assert.is_equal("y", v.dir)
        assert.is_equal(10, v.children[1].h)
        assert.is_nil(v.children[1].w)
    end)

    it("inside: the third's fit is bounded by what the first left", function()
        local node = layout_node(align.horizontal(stub(60), nil, stub(60)))

        -- No second widget: a grow spacer keeps the third at the far edge.
        assert.is_equal(3, #node.children)
        assert.is_equal(60, node.children[1].w)
        assert.is_true(node.children[2].spacer)
        assert.is_nil(node.children[2].w)
        assert.is_equal(38, node.children[3].w)
    end)

    it("inside: a first that takes everything leaves the rest unplaced", function()
        local node = layout_node(align.horizontal(stub(200), stub(10), stub(10)))

        assert.is_equal(1, #node.children)
        assert.is_equal(98, node.children[1].w)
    end)

    it("outside: the second at its fit, the outer widgets grow", function()
        local node = layout_node(align.horizontal(stub(10), stub(20), stub(30)))
        local l = align.horizontal(stub(10), stub(20), stub(30))

        l.expand = "outside"
        node = layout_node(l)
        assert.is_equal(3, #node.children)
        assert.is_nil(node.children[1].w)
        assert.is_equal(20, node.children[2].w)
        assert.is_nil(node.children[3].w)

        -- A missing outer widget leaves its half empty.
        l = align.horizontal(nil, stub(20), stub(30))
        l.expand = "outside"
        node = layout_node(l)
        assert.is_true(node.children[1].spacer)
        assert.is_nil(node.children[1].w)
        assert.is_equal(20, node.children[2].w)
        assert.is_true(node.children[3].raster)
    end)

    it("outside and none: a second that wants it all is placed alone", function()
        for _, mode in ipairs { "outside", "none" } do
            local l = align.horizontal(stub(10), stub(200), stub(30))

            l.expand = mode

            local node = layout_node(l)

            assert.is_equal(1, #node.children, mode)
            assert.is_true(node.children[1].raster, mode)
            assert.is_nil(node.children[1].w, mode)
        end
    end)

    it("outside without a second widget degrades", function()
        local l = align.horizontal(stub(10), nil, stub(30))

        l.expand = "outside"
        assert.is_true(layout_node(l).raster)

        l = align.horizontal(nil, nil, nil)
        l.expand = "outside"
        assert.is_equal(0, #layout_node(l).children)
    end)

    it("none: the second centers in the whole, the outer widgets pinned to their edges", function()
        local l = align.horizontal(stub(10), stub(20), stub(30))

        l.expand = "none"

        local node = layout_node(l)

        assert.is_equal(3, #node.children)
        -- Two grow wrappers around the second, each holding one outer widget.
        assert.is_true(node.children[1].spacer)
        assert.is_same({ x = "left", y = "top" }, node.children[1].align)
        assert.is_equal(10, node.children[1].children[1].w)
        assert.is_equal(20, node.children[2].w)
        assert.is_same({ x = "right", y = "top" }, node.children[3].align)
        assert.is_equal(30, node.children[3].children[1].w)

        -- The outer widgets are bounded by half of what the second leaves.
        l = align.horizontal(stub(60), stub(20), stub(60))
        l.expand = "none"
        node = layout_node(l)
        assert.is_equal(39, node.children[1].children[1].w)
        assert.is_equal(39, node.children[3].children[1].w)

        -- A missing outer widget leaves its wrapper empty.
        l = align.horizontal(nil, stub(20), stub(30))
        l.expand = "none"
        node = layout_node(l)
        assert.is_equal(0, #node.children[1].children)

        l = align.vertical(utils.widget_stub(5, 10), utils.widget_stub(5, 20), nil)
        l.expand = "none"
        node = layout_node(l)
        assert.is_same({ x = "left", y = "bottom" }, node.children[3].align)
        assert.is_equal(10, node.children[1].children[1].h)
    end)

    it("degrades for an override", function()
        local l = align.horizontal(stub(10), stub(20), stub(30))

        rawset(l, "layout", function(self, ...) return align.layout(self, ...) end)
        assert.is_true(layout_node(l).raster)
    end)
end)

describe("wibox.clay stack", function()
    local stack = require("wibox.layout.stack")


    it("floats each child over the one before, sized to the stack", function()
        local a, b = utils.widget_stub(10, 5), utils.widget_stub(20, 5)
        local node = layout_node(stack(a, b))

        assert.is_equal(2, #node.children)
        for _, wrapper in ipairs(node.children) do
            assert.is_true(wrapper.float)
            assert.is_same({ 0, 0, 0, 0 }, wrapper.pad)
            assert.is_true(wrapper.spacer)
            assert.is_equal(1, #wrapper.children)
            assert.is_true(wrapper.children[1].raster)
            assert.is_nil(wrapper.children[1].w)
        end

        local _, leaves = compile(BG, margin(stack(a, b), 1, 1, 1, 1), BG)

        assert.is_equal(a, leaves[1].hierarchy:get_widget())
        assert.is_equal(b, leaves[2].hierarchy:get_widget())
    end)

    it("turns spacing and offsets into padding around each child", function()
        local l = stack(utils.widget_stub(10, 5), utils.widget_stub(20, 5))

        l.spacing = 3
        l.horizontal_offset = 4
        l.vertical_offset = 1

        local node = layout_node(l)

        assert.is_same({ 3, 3 + 2 * 4, 3, 3 + 2 * 1 }, node.children[1].pad)
        assert.is_same({ 3 + 4, 3 + 4, 3 + 1, 3 + 1 }, node.children[2].pad)
    end)

    it("declares only the first child with top_only", function()
        local l = stack(utils.widget_stub(10, 5), utils.widget_stub(20, 5))

        l.top_only = true

        local node = layout_node(l)

        assert.is_equal(1, #node.children)
    end)

    it("degrades for a negative offset and an override", function()
        local l = stack(utils.widget_stub(10, 5), utils.widget_stub(20, 5))

        l.horizontal_offset = -2
        assert.is_true(layout_node(l).raster)

        l = stack(utils.widget_stub(10, 5))
        rawset(l, "layout", function(self, ...) return stack.layout(self, ...) end)
        assert.is_true(layout_node(l).raster)
    end)
end)

describe("wibox.clay place", function()
    local place = require("wibox.container.place")


    it("aligns a child fixed at its fit on both axes", function()
        local node = layout_node(place(utils.widget_stub(10, 20)))

        assert.is_same({ x = "center", y = "center" }, node.align)
        assert.is_equal(1, #node.children)
        assert.is_equal(10, node.children[1].w)
        assert.is_equal(20, node.children[1].h)

        node = layout_node(place(utils.widget_stub(10, 20), "right", "bottom"))
        assert.is_same({ x = "right", y = "bottom" }, node.align)
    end)

    it("grows the child on an axis content_fill_* names", function()
        local c = place(utils.widget_stub(10, 20))

        c.content_fill_horizontal = true

        local node = layout_node(c)

        assert.is_nil(node.children[1].w)
        assert.is_equal(20, node.children[1].h)

        c.content_fill_vertical = true
        node = layout_node(c)
        assert.is_nil(node.children[1].h)
    end)

    it("converts with no child, and degrades for an override", function()
        assert.is_equal(0, #layout_node(place()).children)

        local c = place(utils.widget_stub(10, 20))

        rawset(c, "layout", function(self, ...) return place.layout(self, ...) end)
        assert.is_true(layout_node(c).raster)
    end)
end)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
