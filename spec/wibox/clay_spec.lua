---------------------------------------------------------------------------
-- Tests for wibox.clay, the widget-tree-to-Clay compile step.
---------------------------------------------------------------------------

local gcolor = require("gears.color")
local gshape = require("gears.shape")
local background = require("wibox.container.background")
local margin = require("wibox.container.margin")
local rotate = require("wibox.container.rotate")
local fixed = require("wibox.layout.fixed")
local base = require("wibox.widget.base")
local gdebug = require("gears.debug")
local wclay = require("wibox.clay")

local BG = gcolor("#102030")
local BG_RGBA = { 0x10/255, 0x20/255, 0x30/255, 1 }
local context = { dpi = 96 }

-- A described color leaf with a preferred size.
local function leaf_widget(width, height)
    local w = base.make_widget()
    w._clay = { name = "leaf", describe = function(_, fg)
        return { w = width or 10, h = height or 10, bg = wclay.solid_rgba(fg) }
    end }
    return w
end

-- compile() walks the widget tree, in a 100x100 drawable: no hierarchy, no
-- drawable, no drawin, no screen.
local function compile(bg, root, fg)
    local drawable = {
        background_color = bg,
        foreground_color = fg,
        background_image = nil,
    }

    return wclay.compile(drawable, root, context, 100, 100)
end

local function node_for(tree, widget)
    for _, item in wclay.bindings(tree) do
        if item.widget == widget then return tree end
    end
    for _, child in ipairs(tree.children or {}) do
        local found = node_for(child, widget)
        if found then return found end
    end
end

-- The child node under a margin, or nil when the child is refused.
local function layout_node(w)
    local tree = compile(BG, margin(w, 1, 1, 1, 1), BG)

    return node_for(tree, w)
end

-- The node for a widget put in a fixed layout, which asks it for its size
-- along the direction rather than handing it a box.
local function fixed_node(w)
    return node_for(compile(BG, margin(fixed.horizontal(w), 1, 1, 1, 1), BG), w)
end

local function degraded(w)
    return layout_node(w) == nil
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
    it("rounds pixels silently and warns once per class and property", function()
        local warning = stub(gdebug, "print_warning")
        local first, second = leaf_widget(), leaf_widget()
        assert.is_equal(2, wclay.pixels(first, "spacing", 2.4))
        assert.is_equal(3, wclay.pixels(first, "spacing", 2.5))
        assert.stub(warning).was_called(0)
        assert.is_equal(0, wclay.pixels(first, "spacing", -1))
        assert.is_equal(0, wclay.pixels(second, "spacing", -1))
        assert.stub(warning).was_called(1)
        assert.stub(warning).was_called_with("wibox.clay: leaf spacing is negative and is 0")
        assert.is_equal(0, wclay.pixels(first, "left", -1))
        assert.stub(warning).was_called(2)
        assert.is_equal(65535, wclay.pixels(first, "right", 65536))
        assert.stub(warning).was_called_with("wibox.clay: leaf right exceeds 65535 and is 65535")
        warning:revert()
    end)

    it("retains intrinsic images beneath independently allocated flex children", function()
        local cairo = require("lgi").cairo
        local imagebox = require("wibox.widget.imagebox")
        local flex = require("wibox.layout.flex")
        local surface = cairo.ImageSurface(cairo.Format.ARGB32, 10, 10)
        local layout = flex.vertical(imagebox(surface), imagebox(surface))

        for _, spacing in ipairs { 0, 10 } do
            layout.spacing = spacing
            local tree = compile(BG, layout, BG)
            local children = tree.children[1].children
            assert.is_equal(2, #children)
            for _, child in ipairs(children) do
                local image = child.children[1]
                assert.is_nil(image.w)
                assert.is_nil(image.h)
                assert.is_nil(image.last_frame_size)
                assert.is_equal(1, image.aspect)
                assert.is_equal(10, image.image_width)
                assert.is_equal(10, image.image_height)
            end
        end
    end)

    it("records both lines when a shape strokes between them", function()
        local ops = wclay.shape_ops(function(cr)
            cr:move_to(1, 2)
            cr:line_to(3, 4)
            cr:stroke()
            cr:move_to(5, 6)
            cr:line_to(7, 8)
        end, 10, 10)

        assert.is_same({ 0, 1, 2, 1, 3, 4, 0, 5, 6, 1, 7, 8 }, ops)
    end)

    it("keeps a transparent background or a gradient shape", function()
        local tree = compile(nil, margin(leaf_widget(), 1, 1, 1, 1), BG)
        assert.is_nil(tree.bg)
        assert.is_equal(1, #tree.children)
        tree = compile(gcolor("linear:0,0:10,0:0,#000000:1,#ffffff"),
            margin(leaf_widget(), 1, 1, 1, 1), BG)
        assert.is_nil(tree.bg)
        assert.is_function(tree.children[1].shape)
        assert.is_equal(2, #tree.children[1].fill.stops)
    end)

    it("converts a drawable whose own background is transparent", function()
        -- The root draws nothing and still takes input over its box, as a
        -- wibox does (an awful.tooltip is one of these).
        local tree = compile(gcolor("#00000000"),
            margin(leaf_widget(), 1, 1, 1, 1), BG)

        assert.is_true(not tree.bg or tree.bg[4] == 0)
        assert.is_equal(2, #chain(tree))
    end)

    it("wraps the widget in a surface background image", function()
        local cairo = require("lgi").cairo
        local surface = cairo.ImageSurface(cairo.Format.ARGB32, 1, 1)
        local tree, leaves = wclay.compile({
            background_color = BG, foreground_color = BG, background_image = surface,
        }, margin(leaf_widget(), 1, 1, 1, 1), context, 100, 100)
        assert.is_equal(surface._native, tree.children[1].image)
        assert.is_equal(1, #tree.children[1].children)
        assert.is_equal(1, #leaves)
    end)

    it("keeps the drawable background when the root is absent or refused", function()
        assert.is_same({}, compile(BG, base.make_widget(), BG).children)
        assert.is_same({}, compile(BG, nil, BG).children)
    end)

    it("maps margins onto padding, the child growing into them", function()
        local w = leaf_widget()
        local tree, leaves = compile(BG, margin(w, 1, 2, 3, 4), BG)
        local nodes = chain(tree)

        assert.is_equal(2, #nodes)
        assert.is_same(BG_RGBA, nodes[1].bg)
        assert.is_same({ 1, 2, 3, 4 }, nodes[1].pad)
        assert.is_nil(nodes[1].border)
        -- The native host clip retains overflow. Its widget grows from the
        -- solved allocation, without a float or previous-drawable-size floor.
        assert.is_nil(nodes[1].float)
        assert.is_equal(100, nodes[1].w)
        assert.is_equal(100, nodes[1].h)
        assert.is_nil(nodes[1].wmin)
        assert.is_nil(nodes[1].hmin)
        assert.is_equal("leaf", nodes[2].class)
        assert.is_equal("grow", nodes[2].w)
        assert.is_equal(10, nodes[2].wmin)
        assert.is_equal(10, nodes[2].hmin)
        assert.is_equal(0, #leaves)
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

        assert.is_same({ 0, 1, 0, 1 }, nodes[1].bg)
        assert.is_same({ 0, 0, 1, 1 }, nodes[1].border)
        assert.is_same({ 2, 2, 2, 2 }, nodes[1].bw)
        assert.is_equal(0, nodes[1].radius)
        assert.is_nil(nodes[1].pad)
    end)

    it("pads a background whose border strategy shrinks its child", function()
        local w = background(leaf_widget(), "#00ff00")

        w.border_width = 2
        w.border_color = "#0000ff"
        w.border_strategy = "inner"

        local nodes = chain(compile(BG, w, BG))

        assert.is_same({ 2, 2, 2, 2 }, nodes[1].pad)
    end)

    it("maps a rounded rectangle onto a corner radius", function()
        local w = background(leaf_widget(), "#00ff00")

        w:set_shape(gshape.rounded_rect, 8)

        local nodes = chain(compile(BG, w, BG))

        assert.is_equal(8, nodes[2].radius)
        assert.is_equal("leaf", nodes[3].class)
        assert.is_nil(nodes[3].radius)
    end)

    it("reads the radius a shape function draws", function()
        local nodes = chain(compile(BG,
            background(leaf_widget(), "#00ff00", function(cr, cw, ch)
                return gshape.rounded_rect(cr, cw, ch, 6)
            end), BG))

        assert.is_equal(6, nodes[2].radius)
        local warning = stub(gdebug, "print_warning")
        for _, shape in ipairs { gshape.circle, gshape.rounded_bar } do
            local w = background(leaf_widget(), "#00ff00", shape)
            local node = layout_node(w)
            assert.is_equal(0, node.radius)
            assert.is_equal(1, #node.children)
        end
        assert.stub(warning).was_called(1)
        assert.stub(warning).was_called_with(
            "wibox.clay: lua.wibox.container.background shape is not a rounded rectangle and draws as its box")
        warning:revert()
    end)

    it("converts a rounded background under a margin", function()
        local w = background(leaf_widget(), "#00ff00")

        w:set_shape(gshape.rounded_rect, 8)

        local tree, leaves = compile(BG, margin(w, 5, 5, 5, 5), BG)
        local nodes = chain(tree)

        assert.is_equal(3, #nodes)
        assert.is_same({ 5, 5, 5, 5 }, nodes[1].pad)
        assert.is_equal(8, nodes[2].radius)
        assert.is_equal("leaf", nodes[3].class)
        assert.is_equal(0, #leaves)
    end)

    it("converts a rounded background over a converting child", function()
        local inner = margin(leaf_widget(), 2, 2, 2, 2)
        local w = background(inner, "#00ff00")

        w:set_shape(gshape.rounded_rect, 8)

        local tree, leaves = compile(BG, w, BG)
        local nodes = chain(tree)

        -- Background and margin share the outer area. Its padding and arc
        -- belong to that element; the inset leaf retains a separate box.
        assert.is_equal(3, #nodes)
        assert.is_equal(8, nodes[2].radius)
        assert.is_same({ 2, 2, 2, 2 }, nodes[2].pad)
        assert.is_equal("leaf", nodes[3].class)
        assert.is_equal(nodes[2], node_for(tree, inner))
        assert.is_equal(0, #leaves)
    end)

    it("converts a rounded background with nothing filling it", function()
        local w = background(leaf_widget())

        w:set_shape(gshape.rounded_rect, 8)

        local nodes = chain(compile(BG, w, BG))

        assert.is_equal(8, nodes[2].radius)
        assert.is_nil(nodes[2].bg)
        assert.is_equal("leaf", nodes[3].class)
    end)

    it("converts a rounded background that also has a border", function()
        local w = background(leaf_widget(), "#00ff00")
        local warning = stub(gdebug, "print_warning")

        w:set_shape(gshape.rounded_rect, 8)
        w.border_width = 2
        w.border_color = "#0000ff"

        local node = layout_node(w)
        assert.is_equal(8, node.radius)
        assert.is_same({ 0, 0, 1, 1 }, node.border)
        assert.is_same({ 2, 2, 2, 2 }, node.bw)
        assert.stub(warning).was_called(0)
        warning:revert()
    end)

    it("converts containers down to the first it cannot", function()
        local w = leaf_widget()
        local stopper = rotate(margin(w, 2, 2, 2, 2))
        local tree, leaves = compile(BG,
            background(margin(stopper, 4, 4, 4, 4), "#00ff00"), BG)
        local nodes = chain(tree)

        -- The refused subtree is absent; purposeful padding belongs to the
        -- painted outer element even without visible content.
        assert.is_equal(1, #nodes)
        assert.is_same({ 0, 1, 0, 1 }, nodes[1].bg)
        assert.is_same({ 4, 4, 4, 4 }, nodes[1].pad)
        assert.is_nil(nodes[2])
    end)

    it("carries the innermost background foreground to the leaf", function()
        local w = background(leaf_widget(), "#00ff00")
        w.fg = gcolor("#ff00ff")
        local nodes = chain(compile(BG, w, BG))
        assert.is_same({ 1, 0, 1, 1 }, nodes[2].bg)
    end)

    it("omits invisible widgets and multiplies opacity through children", function()
        local w = margin(leaf_widget(), 3, 3, 3, 3)
        w.visible = false
        assert.is_same({}, compile(BG, w, BG).children)
        w.visible, w.opacity = true, 0.5
        local nodes = chain(compile(BG, w, BG))
        assert.is_equal(0.5, nodes[2].bg[4])
    end)

    it("tells Clay a forced size where a parent asks for one", function()
        local w = margin(leaf_widget(), 3, 3, 3, 3)

        w.forced_width = 20

        -- A fixed layout asks its child's size along the direction: the
        -- forced width is that answer. A margin hands its child the whole
        -- box, and counts the forced width as the floor.
        local node = fixed_node(w)

        assert.is_equal(20, node.w)
        assert.is_equal("grow", node.h)
        node = layout_node(w)
        assert.is_equal("grow", node.w)
        assert.is_equal(20, node.wmin)
    end)



    it("stops at a subclass that overrides the layout it converted", function()
        local w = margin(leaf_widget(), 3, 3, 3, 3)

        rawset(w, "layout", function() return {} end)
        assert.is_same({}, compile(BG, w, BG).children)
    end)

    it("draws the margins around a child when draw_empty is false", function()
        local w = margin(leaf_widget(), 3, 3, 3, 3)
        local warning = stub(gdebug, "print_warning")

        w.draw_empty = false
        local tree = compile(BG, w, BG)
        assert.is_equal(1, #tree.children)
        assert.is_same({ 3, 3, 3, 3 }, tree.pad)
        compile(BG, w, BG)
        assert.stub(warning).was_called(1)
        assert.stub(warning).was_called_with(
            "wibox.clay: lua.wibox.container.margin draw_empty is false and the margins are drawn around an empty child")
        warning:revert()
    end)
end)

describe("wibox.clay cache", function()
    local drawable = { background_color = BG, foreground_color = BG }
    local function recompile(root, fg)
        drawable.foreground_color = fg or BG
        return wclay.compile(drawable, root, context, 100, 100)
    end
    local function leaves(tree)
        return tree.children[1].children
    end

    it("binds a content-sized image to its original widget and preserves allocation boundaries", function()
        local cairo = require('lgi').cairo
        local imagebox = require('wibox.widget.imagebox')
        local src = cairo.ImageSurface(cairo.Format.ARGB32, 20, 10)
        local image = imagebox(src, false)
        local wrapper = margin(image, 0, 0, 0, 0)
        local host = {_attachment_fit = true}
        local function build(root)
            return wclay.compile(host, root or wrapper, context, 100, 100)
        end
        local first, images = build()
        local node = node_for(first, image)
        assert.is_equal(src._native, node.image)
        assert.is_equal('fit', node.w)
        assert.is_equal('fit', node.h)
        assert.is_equal(20, node.image_width)
        assert.is_equal(10, node.image_height)
        assert.is_equal(20, node.wmax)
        assert.is_equal(10, node.hmax)
        assert.is_nil(node.last_frame_size)
        assert.is_equal(node, images[1].node)
        local token = node.occurrence
        assert.is_equal(token, node_for(build(), image).occurrence)

        -- A larger minimum is an input area even where the image is empty.
        image.forced_width = 40
        wclay.invalidate(host, image)
        local bounded = node_for(build(), image)
        assert.is_nil(bounded.image)
        assert.is_equal(token, bounded.occurrence)
        assert.is_equal(src._native, bounded.children[1].image)
        assert.is_equal(40, bounded.w)

        image.forced_width = nil
        wclay.invalidate(host, image)
        local restored = node_for(build(), image)
        assert.is_equal(src._native, restored.image)
        assert.is_equal(token, restored.occurrence)
        -- A definite drawable still allocates the imagebox its whole area.
        host._attachment_fit = nil
        assert.is_nil(node_for(build(), image).image)
    end)

    it("shares a content host without changing cached bindings or nested paint", function()
        local host = {_attachment_fit = true, background_color = '#00000000'}
        local leaf = leaf_widget(10, 10)
        local pad = margin(leaf, 4, 4, 4, 4)
        local root = background(pad, '#0000ff')
        local function build()
            return wclay.compile(host, root, context, 100, 100)
        end
        local first = build()
        assert.is_equal(first, node_for(first, root))
        assert.is_equal(first, node_for(first, pad))
        assert.is_same({4, 4, 4, 4}, first.pad)
        local inner = node_for(first, leaf)
        local token = first.occurrence
        local again = build()
        assert.is_equal(inner, node_for(again, leaf))
        assert.is_equal(token, again.occurrence)
        -- Translucent paint retains both layers. An opaque rectangular child
        -- covers the host background completely and keeps the shared area.
        host.background_color = '#ff000080'
        assert.is_equal(token, node_for(build(), root).occurrence)
        root.bg = '#0000ff80'
        wclay.invalidate(host, root)
        local distinct = build()
        assert.is_not_equal(distinct, node_for(distinct, root))
        assert.is_equal(token, node_for(distinct, root).occurrence)
        assert.is_equal(inner, node_for(distinct, leaf))
        host.background_color = nil
        local restored = build()
        assert.is_equal(restored, node_for(restored, root))
        assert.is_equal(token, restored.occurrence)
    end)

    it("recompiles a child when its parent starts allocating a minimum extent", function()
        local child, root = leaf_widget(), base.make_widget()
        local minimum, calls = 0, 0
        local describe = child._clay.describe
        child._clay.describe = function(...)
            calls = calls + 1
            return describe(...)
        end
        wclay.describe_widget(root, function()
            return {fit=true, wmin=minimum, pad={1,1,1,1},
                specs={{widget=child,w='grow',h='grow'}}}
        end, 'content-root')
        local first = node_for(recompile(root), child)
        assert.is_equal(10, first.w) -- An authored size in a FIT parent remains fixed.
        assert.is_equal(first, node_for(recompile(root), child))
        assert.is_equal(1, calls)
        minimum = 40
        wclay.invalidate(drawable, root)
        local allocated = node_for(recompile(root), child)
        assert.is_equal('grow', allocated.w)
        assert.is_equal(10, allocated.wmin)
        assert.is_equal(first.occurrence, allocated.occurrence)
        assert.is_equal(2, calls)
        minimum = 0
        wclay.invalidate(drawable, root)
        local restored = node_for(recompile(root), child)
        assert.is_equal(10, restored.w)
        assert.is_equal(first.occurrence, restored.occurrence)
        assert.is_equal(3, calls)
    end)

    it("keeps a sibling's subtree and describes the marked widget again", function()
        local a, b = leaf_widget(), leaf_widget()
        local root = margin(fixed.horizontal(a, b), 1, 1, 1, 1)
        local first = leaves(recompile(root))
        wclay.invalidate(drawable, a)
        local second = leaves(recompile(root))
        assert.is_not_equal(first[1], second[1])
        assert.is_equal(first[2], second[2])
        assert.is_same(first[1], second[1])
    end)

    it("describes everything again when the foreground or the size changes", function()
        local a = leaf_widget()
        local root = margin(fixed.horizontal(a), 1, 1, 1, 1)
        local first = leaves(recompile(root))
        assert.is_equal(first[1], leaves(recompile(root))[1])
        assert.is_not_equal(first[1], leaves(recompile(root, "#ff0000"))[1])
        local second = leaves(recompile(root, "#ff0000"))
        assert.is_not_equal(second[1], wclay.compile(drawable, root, context, 50, 50)
            .children[1].children[1])
    end)

    it("fades a kept subtree once and keeps refused widgets wired", function()
        local a, refused = leaf_widget(), base.make_widget()
        local row = fixed.horizontal(a, refused)
        local box = background(row)
        box.opacity = 0.5
        local root = margin(box, 1, 1, 1, 1)
        recompile(root)
        wclay.invalidate(drawable, box)
        local tree = recompile(root)
        local node = node_for(tree, a)
        assert.is_equal(0.5, node.bg[4])
        assert.is_equal(row, tree.widgets[refused][1].parent.widget)
    end)

    it("reuses repeated placements and invalidates every occurrence of a changed object", function()
        local shared = leaf_widget()
        local describe, calls = shared._clay.describe, 0
        shared._clay.describe = function(...)
            calls = calls + 1
            return describe(...)
        end
        local row = fixed.horizontal(background(shared), background(shared))
        local root = margin(row, 1, 1, 1, 1)
        local first = recompile(root)
        assert.is_equal(2, calls)
        local second = recompile(root)
        assert.is_equal(2, calls)
        assert.is_equal(first.children[1].children[1],
            second.children[1].children[1])
        shared:set_forced_width(23)
        wclay.invalidate(drawable, shared)
        local third = recompile(root)
        assert.is_equal(4, calls)
        local children = third.children[1].children
        assert.is_equal(23, children[1].children[1].w)
        assert.is_equal(23, children[2].children[1].w)
    end)
end)

describe("wibox.clay host contributions", function()
    local function custom(properties, child)
        local widget = base.make_widget(nil, nil, {enable_properties = true})
        wclay.describe_widget(widget, function()
            local node = {}
            for key, value in pairs(properties) do node[key] = value end
            if child then node.specs = wclay.whole_box(child) end
            return node
        end, 'custom')
        return widget
    end

    it("shares a definite host with equivalent built-in and custom leaves", function()
        for _, widget in ipairs {background(nil, '#0000ff'),
                custom({bg = {0, 0, 1, 1}})} do
            local tree = compile(BG, widget)
            assert.is_equal(tree, node_for(tree, widget))
            assert.is_same({0, 0, 1, 1}, tree.bg)
            assert.is_equal(100, tree.w)
            assert.is_equal(100, tree.h)
            assert.is_equal(0, #tree.children)
        end
    end)

    it("folds capped definite allocations and retains possible overflow", function()
        local properties = {wmax = 100, hmax = 100, bg = {0, 0, 1, 1}}
        local widget = custom(properties)
        local host = {background_color = BG}
        local function build()
            wclay.invalidate(host, widget)
            return wclay.compile(host, widget, context, 100, 100)
        end
        local tree = build()
        assert.is_equal(tree, node_for(tree, widget))
        local token = tree.occurrence
        properties.wmax = 101
        tree = build()
        assert.is_not_equal(tree, node_for(tree, widget))
        assert.is_equal(token, node_for(tree, widget).occurrence)
        properties.wmax = 99
        tree = build()
        assert.is_not_equal(tree, node_for(tree, widget))
        properties.wmax = 100
        assert.is_equal(token, build().occurrence)
        local text = leaf_widget(1000, 20)
        local container = custom(properties, text)
        tree = wclay.compile(host, container, context, 100, 100)
        assert.is_not_equal(tree, node_for(tree, container))
    end)

    it("keeps translucent paint, rounded clips and distinct padding areas", function()
        local text = leaf_widget()
        local content = background(text, '#0000ff80')
        local host = {_attachment_fit = true, background_color = '#ff0000'}
        local function build()
            wclay.invalidate(host, content)
            return wclay.compile(host, content, context, 100, 100)
        end
        local tree = build()
        assert.is_not_equal(tree, node_for(tree, content))
        content.bg = '#0000ff'
        tree = build()
        assert.is_equal(tree, node_for(tree, content))
        content.shape = gshape.rounded_rect
        tree = build()
        assert.is_not_equal(tree, node_for(tree, content))
        content.shape = nil
        content.widget = margin(text, 4, 8, 2, 6)
        tree = build()
        assert.is_equal(tree, node_for(tree, content))
        assert.is_not_equal(tree, node_for(tree, text))
        assert.is_same({4, 8, 2, 6}, tree.pad)
    end)

    it("omits zero-area paint and restores the original occurrence on content changes", function()
        local empty = background(nil, '#ff0000')
        local leaf = leaf_widget()
        local row = fixed.horizontal(empty, leaf)
        row.spacing = 4
        local host = {}
        local function build()
            wclay.invalidate(host, empty)
            return wclay.compile(host, row, context, 100, 100)
        end
        local tree = build()
        assert.is_nil(node_for(tree, empty))
        local token = tree.widgets[empty][1].id
        empty.forced_width = 12
        tree = build()
        assert.is_equal(token, node_for(tree, empty).occurrence)
        empty.forced_width = nil
        empty.widget = leaf_widget()
        tree = build()
        assert.is_equal(token, node_for(tree, empty).occurrence)
        empty.widget = nil
        assert.is_nil(node_for(build(), empty))
    end)

    it("invalidates covered paint throughout cached fragments when host opacity changes", function()
        local content = background(leaf_widget(), '#0000ff')
        local outer = background(content, '#00ff00')
        local host = {_attachment_fit=true, background_color='#ff0000',
            drawable={_clay_opaque=true}}
        local function build()
            return wclay.compile(host, outer, context, 100, 100)
        end
        local tree = build()
        assert.is_equal(tree, node_for(tree, content))
        local token = node_for(tree, content).bindings.next.item.id
        host.drawable._clay_opaque=false
        tree = build()
        assert.is_not_equal(tree, node_for(tree, outer))
        assert.is_not_equal(node_for(tree, outer), node_for(tree, content))
        host.drawable._clay_opaque=true
        tree = build()
        assert.is_equal(tree, node_for(tree, content))
        assert.is_equal(token, node_for(tree, content).bindings.next.item.id)
    end)
end)

describe("wibox.clay fixed", function()
    it("maps direction and spacing, children at their size along it, whole across", function()
        local l = fixed.horizontal(leaf_widget(10, 5),
            margin(leaf_widget(20, 5), 1, 1, 1, 1))

        l.spacing = 4

        local node = layout_node(l)

        assert.is_equal("x", node.dir)
        assert.is_equal(4, node.gap)
        assert.is_equal(2, #node.children)
        assert.is_equal("leaf", node.children[1].class)
        assert.is_equal(10, node.children[1].w)
        assert.is_equal("grow", node.children[1].h)
        assert.is_equal(5, node.children[1].hmin)
        -- A converted child wraps its content, which is Clay's default.
        assert.is_nil(node.children[2].w)
        assert.is_equal("grow", node.children[2].h)

        local v = layout_node(fixed.vertical(leaf_widget(5, 10)))

        assert.is_equal("y", v.dir)
        assert.is_equal(10, v.children[1].h)
        assert.is_equal("grow", v.children[1].w)
    end)

    it("grows the last child when fill_space is set", function()
        local l = fixed.horizontal(leaf_widget(10, 5), leaf_widget(20, 5))

        l:fill_space(true)

        local node = layout_node(l)

        assert.is_equal(10, node.children[1].w)
        assert.is_equal("grow", node.children[2].w)
        assert.is_equal(20, node.children[2].wmin)
    end)

    it("omits invisible children", function()
        local hidden = leaf_widget(10, 5)

        hidden._private.visible = false

        local l = fixed.horizontal(leaf_widget(10, 5), hidden,
            leaf_widget(0, 5), leaf_widget(20, 5))
        local node = layout_node(l)

        assert.is_equal(3, #node.children)
        assert.is_equal(0, node.children[2].w)
        assert.is_equal(20, node.children[3].w)
    end)

    it("rounds spacing, ignores spacing widgets and refuses overrides", function()
        local warning = stub(gdebug, "print_warning")
        local l = fixed.horizontal(leaf_widget(10, 5), leaf_widget(10, 5))
        l.spacing = 3
        l.spacing_widget = leaf_widget(3, 5)
        assert.is_equal(3, layout_node(l).gap)
        assert.stub(warning).was_called(1)
        warning:revert()

        warning = stub(gdebug, "print_warning")
        l = fixed.horizontal(leaf_widget(10, 5), leaf_widget(10, 5))
        l.spacing = -2
        assert.is_equal(0, layout_node(l).gap)
        assert.stub(warning).was_called(1)
        warning:revert()

        warning = stub(gdebug, "print_warning")
        l.spacing = 2.5
        assert.is_equal(3, layout_node(l).gap)
        assert.stub(warning).was_called(0)
        warning:revert()

        l = fixed.horizontal(leaf_widget(10, 5))
        rawset(l, "layout", function(self, ...) return fixed.layout(self, ...) end)
        assert.is_true(degraded(l))

        l = fixed.horizontal(leaf_widget(10, 5))
        l._clay = { name = "cutoff_override", describe = fixed._clay.describe }
        rawset(l, "fit", function() return 0, 0 end)
        local warning = stub(gdebug, "print_warning")
        assert.is_true(degraded(l))
        assert.is_true(degraded(l))
        assert.stub(warning).was_called(1)
        warning:revert()
    end)
end)

describe("wibox.clay flex", function()
    local flex = require("wibox.layout.flex")

    it("grows every child along the direction, with max_widget_size as the ceiling", function()
        local l = flex.horizontal(leaf_widget(10, 5), leaf_widget(50, 5))

        l.spacing = 2

        local node = layout_node(l)

        assert.is_equal("x", node.dir)
        assert.is_equal(2, node.gap)
        assert.is_equal(2, #node.children)
        assert.is_equal("grow", node.children[1].w)
        assert.is_equal("grow", node.children[1].h)
        assert.is_nil(node.children[1].wmax)
        assert.is_equal("leaf", node.children[2].class)

        l.max_widget_size = 30
        node = layout_node(l)
        assert.is_equal(30, node.children[1].wmax)
        assert.is_equal(30, node.children[2].wmax)
        assert.is_nil(node.children[2].hmax)

        local v = flex.vertical(leaf_widget(5, 10))

        v.max_widget_size = 12
        node = layout_node(v)
        assert.is_equal("y", node.dir)
        assert.is_equal(12, node.children[1].hmax)
    end)

    it("rounds spacing, ignores spacing widgets and refuses overrides", function()
        local warning = stub(gdebug, "print_warning")
        local l = flex.horizontal(leaf_widget(10, 5), leaf_widget(10, 5))
        l.spacing = 3
        l.spacing_widget = leaf_widget(3, 5)
        assert.is_equal(3, layout_node(l).gap)
        assert.stub(warning).was_called(1)
        warning:revert()

        warning = stub(gdebug, "print_warning")
        l = flex.horizontal(leaf_widget(10, 5), leaf_widget(10, 5))
        l.spacing = -2
        assert.is_equal(0, layout_node(l).gap)
        assert.stub(warning).was_called(1)
        warning:revert()

        warning = stub(gdebug, "print_warning")
        l.spacing = 2.5
        assert.is_equal(3, layout_node(l).gap)
        assert.stub(warning).was_called(0)
        warning:revert()

        l = flex.horizontal(leaf_widget(10, 5))
        rawset(l, "layout", function(self, ...) return flex.layout(self, ...) end)
        assert.is_true(degraded(l))
    end)
end)

describe("wibox.clay align", function()
    local align = require("wibox.layout.align")
    local warning_stub = stub

    local function stub(w)
        return leaf_widget(w, 5)
    end

    it("inside: outer widgets at their size, the second grows between", function()
        local node = layout_node(align.horizontal(stub(10), stub(200), stub(20)))

        assert.is_equal("x", node.dir)
        assert.is_equal(3, #node.children)
        assert.is_equal(10, node.children[1].w)
        assert.is_equal("grow", node.children[2].w)
        assert.is_equal(20, node.children[3].w)
        for _, child in ipairs(node.children) do
            assert.is_equal("leaf", child.class)
            assert.is_equal("grow", child.h)
        end

        local v = layout_node(align.vertical(leaf_widget(5, 10), stub(5), nil))

        assert.is_equal("y", v.dir)
        assert.is_equal(10, v.children[1].h)
        assert.is_equal("grow", v.children[1].w)
    end)

    it("inside: with no second widget a grow spacer keeps the third at the far edge", function()
        local node = layout_node(align.horizontal(stub(60), nil, stub(60)))

        assert.is_equal(3, #node.children)
        assert.is_equal(60, node.children[1].w)
        assert.is_true(node.children[2].spacer)
        assert.is_equal("grow", node.children[2].w)
        assert.is_equal(60, node.children[3].w)
    end)

    it("outside: the second at its size, the outer widgets grow", function()
        local l = align.horizontal(stub(10), stub(20), stub(30))

        l.expand = "outside"

        local node = layout_node(l)

        assert.is_equal(3, #node.children)
        assert.is_equal("grow", node.children[1].w)
        assert.is_equal(10, node.children[1].wmin)
        assert.is_equal(20, node.children[2].w)
        assert.is_equal("grow", node.children[3].w)

        -- A missing outer widget leaves its half empty.
        l = align.horizontal(nil, stub(20), stub(30))
        l.expand = "outside"
        node = layout_node(l)
        assert.is_true(node.children[1].spacer)
        assert.is_equal("grow", node.children[1].w)
        assert.is_equal(20, node.children[2].w)
        assert.is_equal("leaf", node.children[3].class)
    end)

    it("outside without a second widget pins the outer widgets", function()
        local l = align.horizontal(stub(10), nil, stub(30))

        l.expand = "outside"
        local warning = warning_stub(gdebug, "print_warning")
        local node = layout_node(l)
        -- The middle slot holds nothing and takes nothing, so it is absent.
        assert.is_equal(2, #node.children)
        assert.is_same({ x = "left", y = "top" }, node.children[1].align)
        assert.is_same({ x = "right", y = "top" }, node.children[2].align)
        assert.is_equal(l.first, node.children[1].children[1].widget)
        assert.is_equal(l.third, node.children[2].children[1].widget)
        assert.stub(warning).was_called(1)
        warning:revert()

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
        assert.is_equal("grow", node.children[1].w)
        assert.is_same({ x = "left", y = "top" }, node.children[1].align)
        assert.is_equal(10, node.children[1].children[1].w)
        assert.is_equal(20, node.children[2].w)
        assert.is_same({ x = "right", y = "top" }, node.children[3].align)
        assert.is_equal(30, node.children[3].children[1].w)

        -- A missing outer widget leaves its wrapper empty.
        l = align.horizontal(nil, stub(20), stub(30))
        l.expand = "none"
        node = layout_node(l)
        assert.is_equal(0, #node.children[1].children)

        l = align.vertical(leaf_widget(5, 10), leaf_widget(5, 20), nil)
        l.expand = "none"
        node = layout_node(l)
        assert.is_same({ x = "left", y = "bottom" }, node.children[3].align)
        assert.is_equal(10, node.children[1].children[1].h)
    end)

    it("is refused for an override", function()
        local l = align.horizontal(stub(10), stub(20), stub(30))

        rawset(l, "layout", function(self, ...) return align.layout(self, ...) end)
        assert.is_nil(layout_node(l))
    end)
end)

describe("wibox.clay stack", function()
    local stack = require("wibox.layout.stack")

    it("promotes participating children and invalidates their cached flow role", function()
        local a, b, c = leaf_widget(10, 5), leaf_widget(20, 6), leaf_widget(30, 7)
        local empty = require("wibox.widget.textbox")()
        local missing = base.make_widget()
        local warning = stub(gdebug, "print_warning")
        local l = stack(empty, missing, a, b, c)
        local host = {background_color=BG}
        local function tree()
            return wclay.compile(host, l, context, 200, 100)
        end
        local node = tree()
        assert.is_nil(node_for(node, empty))
        assert.is_nil(node_for(node, missing))
        assert.is_nil(node_for(node, a).float)
        assert.is_true(node_for(node, b).float)
        a:set_visible(false)
        wclay.invalidate(host, a)
        node = tree()
        assert.is_nil(node_for(node, a))
        assert.is_nil(node_for(node, b).float)
        assert.is_true(node_for(node, c).float)
        a:set_visible(true)
        wclay.invalidate(host, a)
        node = tree()
        assert.is_nil(node_for(node, a).float)
        assert.is_true(node_for(node, b).float)
        warning:revert()
    end)

    it("declares nothing without participating children, even with a forced size", function()
        local a = leaf_widget(10, 5)
        a:set_visible(false)
        local l = stack(a, fixed.horizontal(), require("wibox.widget.imagebox")())
        l.forced_width, l.forced_height = 100, 80
        assert.is_nil(layout_node(l))
        assert.is_nil(layout_node(stack()))
        l:add(leaf_widget(20, 10))
        l.top_only = true
        assert.is_equal(1, #layout_node(l).children)
    end)

    it("folds equal content boxes while keeping later floats and bindings", function()
        local a, b = leaf_widget(10, 5), leaf_widget(20, 6)
        local row = fixed.horizontal(a)
        local l = stack(row, b)
        local node = layout_node(l)
        assert.is_equal(node, node_for(node, row))
        assert.is_nil(node_for(node, a).float)
        assert.is_true(node_for(node, b).float)
        assert.is_equal(2, #node.children)
    end)

    it("folds cached content after solved boxes and a spacing change", function()
        local row = fixed.horizontal(leaf_widget(10, 5))
        local l = stack(row, leaf_widget(20, 6))
        local host = {background_color=BG}
        local function tree()
            return wclay.compile(host, l, context, 200, 100)
        end
        tree()
        l.spacing = 1
        wclay.invalidate(host, l)
        local node = tree()
        -- Drawable readback annotates cached declarations after each solve.
        node_for(node, row).box = {x=1,y=1,width=199,height=99}
        l.spacing = 0
        wclay.invalidate(host, l)
        node = tree()
        assert.is_equal(node_for(node, l), node_for(node, row))
    end)

    it("keeps content in flow and later floats at their own size", function()
        local a, b = leaf_widget(10, 5), leaf_widget(20, 5)
        local node = layout_node(stack(a, b))

        assert.is_equal(2, #node.children)
        for i, child in ipairs(node.children) do
            assert.is_equal(i > 1 or nil, child.float)
            assert.is_nil(child.pad)
            assert.is_nil(child.spacer)
            assert.is_equal(i * 10, child.w)
            assert.is_equal(5, child.h)
            assert.is_equal("leaf", child.class)
        end

        local _, leaves = compile(BG, margin(stack(a, b), 1, 1, 1, 1), BG)

        assert.is_equal(0, #leaves)
    end)

    it("insets content and keeps later attachment offsets", function()
        local l = stack(leaf_widget(10, 5), leaf_widget(20, 5))

        l.spacing = 3
        l.horizontal_offset = 4
        l.vertical_offset = 1

        local node = layout_node(l)

        assert.is_same({ 3, 0, 3, 0 }, node.pad)
        assert.is_nil(node.children[1].x)
        assert.is_same({ 7, 4 }, {node.children[2].x, node.children[2].y})
    end)

    it("declares only the first child with top_only", function()
        local l = stack(leaf_widget(10, 5), leaf_widget(20, 5))

        l.top_only = true

        local node = layout_node(l)

        assert.is_equal(1, #node.children)
    end)

    it("rounds offsets, clamps negative offsets and refuses an override", function()
        local l = stack(leaf_widget(10, 5), leaf_widget(20, 5))

        local warning = stub(gdebug, "print_warning")
        l.horizontal_offset = -2
        local node = layout_node(l)
        for _, child in ipairs(node.children) do
            assert.is_equal(child.float and 0 or nil, child.x)
            assert.is_nil(child.pad)
        end
        assert.stub(warning).was_called(1)
        warning:revert()
        warning = stub(gdebug, "print_warning")
        l.horizontal_offset = 1.5
        node = layout_node(l)
        assert.is_nil(node.children[1].x)
        assert.is_equal(2, node.children[2].x)
        assert.stub(warning).was_called(0)
        warning:revert()

        l = stack(leaf_widget(10, 5))
        rawset(l, "layout", function(self, ...) return stack.layout(self, ...) end)
        assert.is_nil(layout_node(l))
    end)
end)

describe("wibox.clay place", function()
    local place = require("wibox.container.place")

    it("attaches a floating child at native points and keeps both bindings", function()
        local child = leaf_widget(10, 20)
        local c = place(child, "right", "bottom")
        local stack = require("wibox.layout.stack")(leaf_widget(1, 1), c)
        local tree = layout_node(stack)
        local node = node_for(tree, c)
        assert.is_equal(node, node_for(tree, child))
        assert.is_equal("leaf", node.class)
        assert.is_true(node.float)
        assert.is_equal(8, node.parent)
        assert.is_equal(8, node.own)
        assert.is_equal(10, node.w)
        c.forced_width = 30
        tree = layout_node(stack)
        assert.is_not_equal(node_for(tree, c), node_for(tree, child))
    end)

    it("invalidates cached float positions when the stack offsets change", function()
        local a, b = place(leaf_widget(10, 20)), leaf_widget(20, 30)
        local stack = require("wibox.layout.stack")(a, b)
        local host = {background_color = BG}
        local context = {}
        wclay.compile(host, stack, context, 200, 100)
        stack.horizontal_offset = 7
        local tree = wclay.compile(host, stack, context, 200, 100)
        assert.is_equal(7, node_for(tree, b).x)
        assert.is_nil(node_for(tree, a).float)
        assert.is_same({x="center", y="center"}, node_for(tree, a).align)
    end)

    it("aligns a child at its size on both axes", function()
        local node = layout_node(place(leaf_widget(10, 20)))

        assert.is_same({ x = "center", y = "center" }, node.align)
        assert.is_equal(1, #node.children)
        assert.is_equal(10, node.children[1].w)
        assert.is_equal(20, node.children[1].h)

        node = layout_node(place(leaf_widget(10, 20), "right", "bottom"))
        assert.is_same({ x = "right", y = "bottom" }, node.align)
    end)

    it("grows the child on an axis content_fill_* names", function()
        local c = place(leaf_widget(10, 20))

        c.content_fill_horizontal = true

        local node = layout_node(c)

        assert.is_equal("grow", node.children[1].w)
        assert.is_equal(20, node.children[1].h)

        c.content_fill_vertical = true
        node = layout_node(c)
        assert.is_equal("grow", node.children[1].h)
    end)

    it("fills the axes fill_* names, where a parent asks its size", function()
        local c = place(leaf_widget(10, 20))

        assert.is_nil(fixed_node(c).w)
        c.fill_horizontal = true
        assert.is_equal("grow", fixed_node(c).w)
    end)

    it("converts with no child, and is refused for an override", function()
        assert.is_equal(0, #layout_node(place()).children)

        local c = place(leaf_widget(10, 20))

        rawset(c, "layout", function(self, ...) return place.layout(self, ...) end)
        assert.is_nil(layout_node(c))
    end)
end)

describe("wibox.clay ratio", function()
    it("ignores spacing and the inner fill strategy", function()
        local ratio = require("wibox.layout.ratio")
        local l = ratio.horizontal(leaf_widget(), leaf_widget())
        local warning = stub(gdebug, "print_warning")
        l.spacing = 5
        assert.is_equal(0, layout_node(l).gap)
        assert.stub(warning).was_called(1)
        l.inner_fill_strategy = "justify"
        assert.is_equal(2, #layout_node(l).children)
        assert.stub(warning).was_called(2)
        warning:revert()
    end)
end)

describe("wibox.clay overflow", function()
    it("rounds the scrollbar width", function()
        local overflow = require("wibox.layout.overflow")
        local l = overflow.vertical(leaf_widget())
        l.scrollbar_width = 3.4
        l._private.scrollbar_enabled = true
        local node = l._clay.describe(l, nil, {})
        assert.is_equal(3, node.specs[2].w)
        assert.is_equal(3, node.specs[2].children[1].w)
    end)
end)

describe("wibox.clay manual", function()
    it("skips callable points and clamps negative sizes without rounding", function()
        local manual = require("wibox.layout.manual")
        local l = manual()
        l:add_at(leaf_widget(), setmetatable({}, { __call = function() return { x = 0, y = 0 } end }))
        l:add_at(leaf_widget(), { x = 1.5, width = -5, height = 2.5 })
        local warning = stub(gdebug, "print_warning")
        local node = l._clay.describe(l)
        assert.is_equal(1, #node.specs)
        assert.is_equal(0, node.specs[1].w)
        assert.is_equal(1.5, node.specs[1].x)
        assert.is_equal(2.5, node.specs[1].h)
        assert.stub(warning).was_called(2)
        assert.stub(warning).was_called_with(
            "wibox.clay: lua.wibox.layout.manual position is a function and the widget is skipped")
        warning:revert()
    end)
end)

describe("wibox.clay margin", function()
    it("gives empty margins no padding when draw_empty is false", function()
        local w = margin(nil, 1, 2, 3, 4)
        w.draw_empty = false
        local node = layout_node(w)
        assert.is_same({ 0, 0, 0, 0 }, node.pad)
        assert.is_equal(0, #node.children)
        w.widget = leaf_widget()
        assert.is_same({ 1, 2, 3, 4 }, layout_node(w).pad)
    end)

    it("rounds margins and ignores a gradient color", function()
        local w = margin(leaf_widget(), 1.5, 1.5, 1.5, 1.5)
        local warning = stub(gdebug, "print_warning")
        assert.is_same({ 2, 2, 2, 2 }, layout_node(w).pad)
        assert.stub(warning).was_called(0)
        w.color = "linear:0,0:10,0:0,#000000:1,#ffffff"
        assert.is_nil(layout_node(w).border)
        assert.stub(warning).was_called(1)
        warning:revert()
    end)
end)

describe("wibox.clay constraint", function()
    it("applies no limit for an unknown strategy", function()
        local constraint = require("wibox.container.constraint")
        local w = constraint(leaf_widget(), "max", 20)
        w._private.strategy_name = "bogus"
        local warning = stub(gdebug, "print_warning")
        local node = w._clay.describe(w)
        assert.is_nil(node.w)
        assert.is_nil(node.wmin)
        assert.is_nil(node.wmax)
        assert.stub(warning).was_called(1)
        warning:revert()
    end)
end)

describe("wibox.clay grid", function()
    it("declares bordered public grids without a refusal", function()
        local grid = require("wibox.layout.grid")
        local w = grid()
        w.border_width = 1
        local warning = stub(gdebug, "print_warning")
        assert.is_not_nil(layout_node(w))
        assert.is_not_nil(layout_node(w))
        assert.stub(warning).was_called(0)
        warning:revert()
    end)
end)

describe("wibox.clay border", function()
    local border = require("wibox.container.border")
    local cairo = require("lgi").cairo
    local function describe(w)
        return border._clay.describe(w, nil, setmetatable({ context = context }, {
            __index = function(_, key) error("border read compiler state: " .. key) end,
        }))
    end

    it("declares authored sides without any host dimensions or source image", function()
        local w = border { widget = leaf_widget(), borders = { left = 4, top = 3, bottom = 7 },
            paddings = { left = 2, right = 1, top = 5, bottom = 6 } }
        local node = describe(w)
        assert.is_equal(3, node.specs[1].h)
        assert.is_equal("grow", node.specs[2].h)
        assert.is_equal(7, node.specs[3].h)
        assert.is_same({2, 1, 5, 6}, node.specs[2].children[2].pad)
        assert.is_equal(4, node.specs[2].children[1].w)
        assert.is_equal(2, #node.specs[2].children)
    end)

    it("crops asymmetric source inputs and replaces slices when borders change", function()
        local w = border { border_image = cairo.ImageSurface(cairo.Format.ARGB32, 30, 20),
            borders = { left = 4, right = 6, top = 3, bottom = 7 } }
        describe(w)
        local first = w._private.slice_cache[96]
        assert.is_equal(20, first.top._private.default.width)
        assert.is_equal(10, first.left._private.default.height)
        assert.is_equal(6, first.bottom_right._private.default.width)
        describe(w)
        assert.is_equal(first, w._private.slice_cache[96])
        w.borders = { left = 2, right = 5, top = 1, bottom = 4 }
        describe(w)
        local second = w._private.slice_cache[96]
        assert.is_not.equal(first, second)
        assert.is_equal(23, second.top._private.default.width)
        assert.is_equal(15, second.left._private.default.height)
        w.border_image = cairo.ImageSurface(cairo.Format.ARGB32, 60, 40)
        describe(w)
        assert.is_equal(53, w._private.slice_cache[96].top._private.default.width)
        assert.is_equal(35, w._private.slice_cache[96].left._private.default.height)
    end)

    it("bounds slices by the source and skips empty sides", function()
        local w = border { border_image = cairo.ImageSurface(cairo.Format.ARGB32, 30, 20),
            borders = { left = 30, top = 20 } }
        local node = describe(w)
        assert.is_equal(14, node.specs[1].children[1].w)
        assert.is_equal(9, node.specs[1].h)
        assert.is_nil(w._private.slice_cache[96].right)
        w.borders = { left = 15, right = 15, top = 10, bottom = 10 }
        describe(w)
        assert.is_equal(2, w._private.slice_cache[96].fill._private.default.width)
        assert.is_equal(2, w._private.slice_cache[96].fill._private.default.height)
    end)

    it("keeps unsliced authored padding independent of source size", function()
        local w = border { widget = leaf_widget(), slice = false, borders = 40, paddings = 2,
            border_image = cairo.ImageSurface(cairo.Format.ARGB32, 30, 20) }
        assert.is_same({42, 42, 42, 42}, describe(w).specs[1].pad)
    end)

    it("retains every unsupported border option as a named refusal", function()
        local warning = stub(gdebug, "print_warning")
        for _, option in ipairs { {"ontop", false},
            {"border_merging", {}}, {"expand_corners", true}, {"border_image_dpi", 192} } do
            local w = border { widget = leaf_widget(), borders = 4 }
            w[option[1]] = option[2]
            assert.is_nil(describe(w))
            assert.stub(warning).was_called_with("wibox.clay: lua.wibox.container.border "
                .. option[1] .. " is not drawn and is left out of the tree")
        end
        warning:revert()
    end)

    it("rounds borders and refuses honor_borders false with a warning", function()
        local border = require("wibox.container.border")
        local cairo = require("lgi").cairo
        local src = cairo.ImageSurface(cairo.Format.ARGB32, 30, 30)
        local w = border { widget = leaf_widget(), border_image = src, borders = 3.4 }
        local warning = stub(gdebug, "print_warning")
        local node = layout_node(w)
        assert.is_equal(3, node.children[1].h)
        assert.is_equal(3, node.children[1].children[1].w)
        assert.stub(warning).was_called(0)
        w.honor_borders = false
        assert.is_nil(layout_node(w))
        assert.stub(warning).was_called(1)
        warning:revert()
    end)
end)

describe("wibox.clay arcchart", function()
    it("keeps asymmetric padding and omits transparent strokes and arcs", function()
        local arcchart = require("wibox.container.arcchart")
        local w = arcchart()
        w.values, w.colors = { 1, 1 }, { "#ff0000", "#00ff00" }
        w.thickness, w.border_width = 6, 2
        w.paddings = { left = 4, right = 0, top = 2, bottom = 2 }
        w.bg = "#0000ff"
        local warning = stub(gdebug, "print_warning")
        local node = w._clay.describe(w, BG)
        assert.is_same({ 14, 10, 12, 12 }, node.pad)
        assert.stub(warning).was_called(0)
        w.bg = "linear:0,0:10,0:0,#000000:1,#ffffff"
        assert.is_equal(#node.specs - 1, #w._clay.describe(w, BG).specs)
        assert.stub(warning).was_called(1)
        w.border_color = w.bg
        w.colors = { "#ff0000", w.bg }
        assert.is_equal(2, #w._clay.describe(w, BG).specs)
        assert.stub(warning).was_called(3)
        warning:revert()
    end)
end)

describe("wibox.clay radialprogressbar", function()
    it("rounds padding for an odd border width and omits a gradient progress stroke", function()
        local radialprogressbar = require("wibox.container.radialprogressbar")
        local w = radialprogressbar()
        w.border_width = 3
        local warning = stub(gdebug, "print_warning")
        local node = w._clay.describe(w)
        assert.is_same({ 2, 2, 2, 2 }, node.pad)
        assert.is_equal(3, #node.specs)
        assert.stub(warning).was_called(0)
        w.color = "linear:0,0:10,0:0,#000000:1,#ffffff"
        node = w._clay.describe(w)
        assert.is_equal(2, #node.specs)
        assert.stub(warning).was_called(1)
        warning:revert()
    end)
end)

describe("wibox.clay background", function()
    it("ignores a function bgimage and keeps the child", function()
        local w = background(leaf_widget(), BG)
        w.bgimage = function() end
        local warning = stub(gdebug, "print_warning")
        local node = layout_node(w)
        assert.is_nil(node.image)
        assert.is_equal(1, #node.children)
        assert.is_nil(node.children[1].image)
        assert.is_equal("leaf", node.children[1].class)
        assert.stub(warning).was_called(1)
        assert.stub(warning).was_called_with(
            "wibox.clay: lua.wibox.container.background bgimage is a function and is not drawn")
        warning:revert()
    end)

    it("rounds fractional border widths silently", function()
        local w = background(leaf_widget(), BG)
        w.border_width = 1.4
        local warning = stub(gdebug, "print_warning")
        assert.is_same({ 1, 1, 1, 1 }, layout_node(w).bw)
        assert.stub(warning).was_called(0)
        warning:revert()
    end)

    it("keeps a gradient's rounded path and border", function()
        local w = background(leaf_widget(), "linear:0,0:100,0:0,#000000:1,#ffffff")
        w:set_shape(gshape.rounded_rect, 8)
        w.border_width, w.border_color = 2, "#0000ff"
        local warning = stub(gdebug, "print_warning")
        local node = layout_node(w)
        assert.is_nil(node.bg)
        assert.is_equal(8, node.radius)
        assert.is_equal(2, #node.fill.stops)
        assert.is_same(wclay.shape_ops(gshape.rounded_rect, 100, 100, 0, 0, 8),
            node.shape(100, 100))
        assert.is_same({ 0, 0, 1, 1 }, node.border)
        assert.is_same({ 2, 2, 2, 2 }, node.bw)
        assert.stub(warning).was_called(0)
        warning:revert()
    end)

    it("omits a gradient border and its inner padding", function()
        local w = background(leaf_widget(), BG)
        w.border_width = 2
        w.border_color = "linear:0,0:100,0:0,#000000:1,#ffffff"
        w.border_strategy = "inner"
        local warning = stub(gdebug, "print_warning")
        local node = layout_node(w)
        assert.is_nil(node.border)
        assert.is_nil(node.bw)
        assert.is_nil(node.pad)
        assert.stub(warning).was_called(1)
        assert.stub(warning).was_called_with(
            "wibox.clay: lua.wibox.container.background shape_border_color is not solid and the border is transparent")
        warning:revert()
    end)

    it("makes a surface pattern transparent while keeping radius and border", function()
        local cairo = require("lgi").cairo
        local surface = cairo.ImageSurface(cairo.Format.ARGB32, 10, 10)
        local w = background(leaf_widget(), cairo.Pattern.create_for_surface(surface))
        w:set_shape(gshape.rounded_rect, 8)
        w.border_width, w.border_color = 2, "#0000ff"
        local warning = stub(gdebug, "print_warning")
        local node = layout_node(w)
        assert.is_nil(node.bg)
        assert.is_nil(node.fill)
        assert.is_nil(node.shape)
        assert.is_equal(8, node.radius)
        assert.is_same({ 0, 0, 1, 1 }, node.border)
        assert.is_same({ 2, 2, 2, 2 }, node.bw)
        assert.stub(warning).was_called(1)
        assert.stub(warning).was_called_with(
            "wibox.clay: lua.wibox.container.background bg is not a solid or a gradient and is transparent")
        warning:revert()
    end)
end)

describe("wibox.clay imagebox", function()
    it("keeps an authored zero image axis distinct from an absent cap", function()
        local imagebox = require("wibox.widget.imagebox")
        local cairo = require("lgi").cairo
        local w = imagebox(cairo.ImageSurface(cairo.Format.ARGB32,20,10))
        w.forced_width = 0
        local image = w._clay.describe(w).specs[1]
        assert.is_equal(0, image.w)
        assert.is_nil(image.h)
        assert.is_equal(20, image.image_width)
        assert.is_equal(10, image.image_height)
        assert.is_nil(image.last_frame_size)
    end)

    it("ignores clipping and fit policy and refuses SVG handles", function()
        local imagebox = require("wibox.widget.imagebox")
        local cairo = require("lgi").cairo
        local src = cairo.ImageSurface(cairo.Format.ARGB32, 20, 10)
        local w = imagebox(src, true, gshape.circle)
        local warning = stub(gdebug, "print_warning")
        local node = w._clay.describe(w)
        assert.is_equal(2, node.specs[1].aspect)
        assert.is_not_nil(node.specs[1].image)
        assert.stub(warning).was_called(1)
        w = imagebox(src)
        w.horizontal_fit_policy = "fit"
        assert.is_equal(2, w._clay.describe(w).specs[1].aspect)
        assert.stub(warning).was_called(2)
        w = imagebox()
        w._private.handle = {}
        assert.is_nil(w._clay.describe(w))
        assert.stub(warning).was_called(3)
        assert.stub(warning).was_called_with(
            "wibox.clay: lua.wibox.widget.imagebox image is an SVG or has no size to render at and is left out of the tree")
        warning:revert()
    end)
end)

describe("wibox.clay progressbar", function()
    it("ignores ticks, rounds margins and omits a gradient bar", function()
        local w = require("wibox.widget.progressbar")()
        w.ticks, w.margins, w.value = true, 1.5, 0.5
        local warning = stub(gdebug, "print_warning")
        local node = w._clay.describe(w)
        assert.is_same({ 2, 2, 2, 2 }, node.pad)
        assert.stub(warning).was_called(1)
        w.color = "linear:0,0:10,0:0,#000000:1,#ffffff"
        assert.is_equal(0, #w._clay.describe(w).specs[1].children)
        assert.stub(warning).was_called(2)
        warning:revert()
    end)

    it("keeps a rounded background and border", function()
        local w = require("wibox.widget.progressbar")()
        w.shape, w.border_width, w.border_color = gshape.rounded_rect, 2, "#0000ff"
        local bg = w._clay.describe(w).specs[1]
        assert.is_equal(10, bg.radius)
        assert.is_same({ 0, 0, 1, 1 }, bg.border)
        assert.is_same({ 2, 2, 2, 2 }, bg.bw)
    end)
end)

describe("wibox.clay slider", function()
    it("ignores the bar border, rounds height and uses the bar color for a gradient handle", function()
        local w = require("wibox.widget.slider")()
        w.bar_border_width, w.bar_height, w.bar_color = 2, 4.4, "#0000ff"
        local warning = stub(gdebug, "print_warning")
        local node = w._clay.describe(w)
        assert.is_equal(4, node.specs[1].children[1].h)
        assert.stub(warning).was_called(1)
        w.handle_color = "linear:0,0:10,0:0,#000000:1,#ffffff"
        assert.is_same({ 0, 0, 1, 1 }, w._clay.describe(w).specs[2].fill)
        assert.stub(warning).was_called(2)
        warning:revert()
    end)
end)

describe("wibox.clay separator", function()
    it("ignores a draw painter", function()
        local w = require("wibox.widget.separator")()
        w._private.draw = function() end
        local warning = stub(gdebug, "print_warning")
        assert.is_equal(1, #w._clay.describe(w).specs)
        assert.stub(warning).was_called(1)
        warning:revert()
    end)
end)

describe("wibox.clay checkbox", function()
    it("uses the main color for a gradient check", function()
        local w = require("wibox.widget.checkbox")()
        w.checked, w.color = true, "#0000ff"
        w.check_color = "linear:0,0:10,0:0,#000000:1,#ffffff"
        local warning = stub(gdebug, "print_warning")
        assert.is_same({ 0, 0, 1, 1 }, w._clay.describe(w).specs[2].fill)
        assert.stub(warning).was_called(1)
        warning:revert()
    end)
end)

describe("wibox.clay graph", function()
    it("rounds the border and omits a gradient data group", function()
        local w = require("wibox.widget.graph")()
        w.border_width, w.border_color, w.color = 1.4, "#0000ff", "#ff0000"
        w:add_value(0.5)
        local warning = stub(gdebug, "print_warning")
        local node = w._clay.describe(w)
        assert.is_same({ 1, 1, 1, 1 }, node.bw)
        assert.is_equal(1, #node.specs)
        assert.stub(warning).was_called(0)
        w.color = "linear:0,0:10,0:0,#000000:1,#ffffff"
        assert.is_equal(0, #w._clay.describe(w).specs)
        assert.stub(warning).was_called(1)
        warning:revert()
    end)
end)

describe("wibox.clay piechart", function()
    it("omits a gradient sector", function()
        local w = require("wibox.widget.piechart")()
        w.data_list, w.display_labels = { { "a", 1 }, { "b", 1 } }, false
        w.colors, w.border_color = { "#ff0000", "#0000ff" }, "#000000"
        local warning = stub(gdebug, "print_warning")
        assert.is_equal(2, #w._clay.describe(w, BG).specs)
        w.colors = { "#ff0000", "linear:0,0:10,0:0,#000000:1,#ffffff" }
        assert.is_equal(1, #w._clay.describe(w, BG).specs)
        assert.stub(warning).was_called(1)
        warning:revert()
    end)
end)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
