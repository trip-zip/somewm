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

local DEFINITE = { w = 100, h = 100, w_definite = true, h_definite = true }
local BG = gcolor("#102030")
local BG_RGBA = { 0x10/255, 0x20/255, 0x30/255, 1 }
local context = { dpi = 96 }
local GRADIENT = "linear:0,0:10,0:0,#000000:1,#ffffff"

-- A surface pattern, which is neither a solid nor a gradient.
local function surface_pattern()
    local cairo = require("lgi").cairo
    return cairo.Pattern.create_for_surface(cairo.ImageSurface(cairo.Format.ARGB32, 1, 1))
end

-- A described color leaf with a preferred size.
local function leaf_widget(width, height)
    local w = base.make_widget()
    w._clay = { name = "leaf", describe = function(_, fg)
        return { w = width or 10, h = height or 10, wsrc = "user", hsrc = "user",
            bg = wclay.solid_rgba(fg) }
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

    it("declares natural images under flex children, which have no height bound", function()
        local cairo = require("lgi").cairo
        local imagebox = require("wibox.widget.imagebox")
        local flex = require("wibox.layout.flex")
        local surface = cairo.ImageSurface(cairo.Format.ARGB32, 10, 10)
        local layout = flex.vertical(imagebox(surface), imagebox(surface))

        for _, spacing in ipairs { 0, 10 } do
            layout.spacing = spacing
            local tree = compile(BG, layout, BG)
            local children = node_for(tree, layout).children
            assert.is_equal(2, #children)
            for _, child in ipairs(children) do
                local image = child.children[1]
                assert.is_equal('fit', image.w)
                assert.is_equal(10, image.wmin)
                assert.is_equal("user", image.wsrc)
                assert.is_equal('fit', image.h)
                assert.is_nil(image.hmin)
                assert.is_nil(image.wmax)
                assert.is_nil(image.hmax)
                assert.is_equal(1, image.aspect)
            end
        end
    end)

    it("lowers a natural image to the flow cap under a flex child", function()
        local cairo = require("lgi").cairo
        local imagebox = require("wibox.widget.imagebox")
        local flex = require("wibox.layout.flex")
        local surface = cairo.ImageSurface(cairo.Format.ARGB32, 48, 48)
        local layout = flex.vertical(imagebox(surface), imagebox(surface))
        local drawable = { background_color = BG, foreground_color = BG, background_image = nil }
        local tree = wclay.compile(drawable, layout, context, 20, 100, {w = 'user', h = 'user'})
        local children = node_for(tree, layout).children
        assert.is_equal(2, #children)
        for _, child in ipairs(children) do
            local image = child.children[1]
            assert.is_equal('fit', image.w)
            assert.is_equal(20, image.wmin)
            assert.is_equal('user', image.wsrc)
            assert.is_equal('fit', image.h)
            assert.is_nil(image.hmin)
        end
    end)

    it("declares the bound times the aspect, within the scaling flags", function()
        local cairo = require('lgi').cairo
        local imagebox = require('wibox.widget.imagebox')
        local icon = imagebox(cairo.ImageSurface(cairo.Format.ARGB32, 20, 10))
        local function image()
            return node_for(compile(BG, icon, BG), icon).children[1]
        end
        assert.is_equal(100, image().wmin)
        icon.upscale = false
        assert.is_equal(20, image().wmin)
        icon.upscale = true
        icon:set_image(cairo.ImageSurface(cairo.Format.ARGB32, 400, 200))
        icon.downscale = false
        assert.is_equal(400, image().wmin)
        icon.resize = false
        local fixed_image = image()
        assert.is_equal(400, fixed_image.w)
        assert.is_equal(200, fixed_image.h)
    end)

    it("uses an authored image axis inside a content-sized host", function()
        local cairo = require('lgi').cairo
        local surface = cairo.ImageSurface(cairo.Format.ARGB32, 20, 10)
        local widget = base.make_widget()
        widget._clay = {describe = function()
            return {specs = {{image = surface._native, aspect = 2,
                image_width = 20, image_height = 10, w = 40}}}
        end}
        local tree = wclay.compile({_attachment_fit = true}, widget, context, 1, 1)
        local image = node_for(tree, widget)
        assert.is_equal(40, image.w)
        assert.is_equal("fit", image.h or "fit")
        assert.is_nil(image.hmin)
        assert.is_nil(image.hmax)
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
        assert.is_equal("leaf", nodes[2].name)
        assert.is_equal("grow", nodes[2].w)
        assert.is_equal(10, nodes[2].wmin)
        assert.is_equal(10, nodes[2].hmin)
        assert.is_equal("user", nodes[2].wsrc)
        assert.is_equal("user", nodes[2].hsrc)
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
        assert.is_same({ 0, 1, 0, 1 }, nodes[2].bg)
        assert.is_nil(nodes[2].shape)
        assert.is_equal("leaf", nodes[3].name)
        assert.is_nil(nodes[3].radius)
    end)

    it("reads the radius a shape function draws", function()
        local nodes = chain(compile(BG,
            background(leaf_widget(), "#00ff00", function(cr, cw, ch)
                return gshape.rounded_rect(cr, cw, ch, 6)
            end), BG))

        assert.is_equal(6, nodes[2].radius)
    end)

    it("fills nonrectangular backgrounds along their paths without warning", function()
        local warning = stub(gdebug, "print_warning")
        for _, shape in ipairs { gshape.circle, gshape.rounded_bar } do
            local w = background(leaf_widget(), "#00ff00", shape)
            local node = layout_node(w)
            assert.is_nil(node.radius)
            assert.is_nil(node.bg)
            assert.is_nil(node.bw)
            assert.is_function(node.shape)
            assert.is_same({ 0, 1, 0, 1 }, node.fill)
            assert.is_same(wclay.shape_ops(shape, 40, 20, 0, 0), node.shape(40, 20))
            assert.is_equal(1, #node.children)
        end
        assert.stub(warning).was_called(0)
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
        assert.is_equal("leaf", nodes[3].name)
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
        assert.is_equal("leaf", nodes[3].name)
        assert.is_equal(nodes[2], node_for(tree, inner))
        assert.is_equal(0, #leaves)
    end)

    it("converts a rounded background with nothing filling it", function()
        local w = background(leaf_widget())

        w:set_shape(gshape.rounded_rect, 8)

        local nodes = chain(compile(BG, w, BG))

        assert.is_equal(8, nodes[2].radius)
        assert.is_nil(nodes[2].bg)
        assert.is_equal("leaf", nodes[3].name)
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
        local stopper = base.make_widget(nil, "spec-stopper")
        stopper.draw = function() end
        local warning = stub(gdebug, "print_warning")
        local tree = compile(BG, background(margin(stopper, 4, 4, 4, 4), "#00ff00"), BG)
        local nodes = chain(tree)

        -- The refused subtree is absent; purposeful padding belongs to the
        -- painted outer element even without visible content.
        assert.is_equal(1, #nodes)
        assert.is_same({ 0, 1, 0, 1 }, nodes[1].bg)
        assert.is_same({ 4, 4, 4, 4 }, nodes[1].pad)
        assert.is_nil(nodes[2])
        assert.stub(warning).was_called_with("wibox.clay: spec-stopper draws itself (:draw) "
            .. "and is left out of the tree")
        warning:revert()
    end)

    it("rotates and mirrors the child's description", function()
        local warning = stub(gdebug, "print_warning")
        for _, case in ipairs {
            { rotate(nil, "east"), "90", { 3, 4, 2, 1 }, 4, 10 },
            { require("wibox.container.mirror")(nil, { horizontal = true }), "flipped", { 2, 1, 3, 4 }, 10, 4 },
        } do
            local w = leaf_widget(10, 4)
            local m = margin(w, 1, 2, 3, 4)
            case[1].widget = m
            local tree = compile(BG, case[1], BG)
            local outer, leaf = node_for(tree, m), node_for(tree, w)
            assert.is_equal(case[2], outer.transform)
            assert.is_same(case[3], outer.pad)
            assert.is_equal(case[2], leaf.transform)
            assert.is_same({ case[4], case[5] }, { leaf.wmin or leaf.w, leaf.hmin or leaf.h })
        end
        assert.stub(warning).was_called(0)
        warning:revert()
    end)

    it("refuses a rotate around a mirror", function()
        local warning = stub(gdebug, "print_warning")
        local leaf = leaf_widget()
        local turned = rotate(require("wibox.container.mirror")(leaf, { horizontal = true }), "east")
        local tree = compile(BG, margin(turned, 1, 1, 1, 1), BG)
        assert.is_nil(node_for(tree, leaf))
        assert.is_same({}, node_for(tree, turned).children)
        assert.stub(warning).was_called(1)
        assert.is_truthy(warning.calls[1].vals[1]:find("transforms do not nest", 1, true))
        warning:revert()
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
        assert.is_equal("user", node.wsrc)
        assert.is_equal("grow", node.h)
        node = layout_node(w)
        assert.is_equal("grow", node.w)
        assert.is_equal(20, node.wmin)
        assert.is_equal("user", node.wsrc)
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
        assert.is_equal(20, node.w)
        assert.is_equal(10, node.h)
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
        assert.is_equal("user", bounded.wsrc)

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
        -- A content-sized host never folds a FIXED child (it would become
        -- the drawin's geometry); a GROW leaf folds.
        local text = leaf_widget('grow', 'grow')
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
        local content = background(leaf_widget('grow', 'grow'), '#0000ff')
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
        assert.is_equal("leaf", node.children[1].name)
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

    it("rounds spacing, declares spacing widgets and refuses overrides", function()
        local warning = stub(gdebug, "print_warning")
        local l = fixed.horizontal(leaf_widget(10, 5), leaf_widget(10, 5))
        l.spacing = 3
        l.spacing_widget = leaf_widget(3, 5)
        assert.is_equal(0, layout_node(l).gap)
        assert.is_equal(3, layout_node(l).children[2].w)
        assert.stub(warning).was_not_called()
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
        assert.is_equal("leaf", node.children[2].name)

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

    it("rounds spacing, declares spacing widgets and refuses overrides", function()
        local warning = stub(gdebug, "print_warning")
        local l = flex.horizontal(leaf_widget(10, 5), leaf_widget(10, 5))
        l.spacing = 3
        l.spacing_widget = leaf_widget(3, 5)
        assert.is_equal(0, layout_node(l).gap)
        assert.is_equal(3, layout_node(l).children[2].w)
        assert.stub(warning).was_not_called()
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
            assert.is_equal("leaf", child.name)
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
        assert.is_equal("leaf", node.children[3].name)
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

    it("keeps a childless painted background after the stack image", function()
        local cairo = require("lgi").cairo
        local image = require("wibox.widget.imagebox")(
            cairo.ImageSurface(cairo.Format.ARGB32, 50, 110))
        local overlay = background(nil, "#000000aa")
        local node = layout_node(stack(image, overlay))
        local image_node, overlay_node = node_for(node, image), node_for(node, overlay)
        local image_leaf = image_node
        while not image_leaf.image do image_leaf = assert(image_leaf.children[1]) end
        assert.is_not_nil(image_leaf.image)
        assert.is_true(overlay_node.float)
        assert.is_equal("grow", overlay_node.w)
        assert.is_equal("grow", overlay_node.h)
        assert.is_same({0, 0, 0, 170/255}, overlay_node.bg)
        assert.is_equal(0, #(overlay_node.children or {}))
        local order = {}
        local function visit(n)
            if n.image or n == overlay_node then order[#order + 1] = n end
            for _, child in ipairs(n.children or {}) do visit(child) end
        end
        visit(node)
        assert.is_same({image_leaf, overlay_node}, order)
    end)

    it("omits a childless transparent background in a stack", function()
        local image = leaf_widget(50, 110)
        local overlay = background(nil, "#00000000")
        local node = layout_node(stack(image, overlay))
        assert.is_nil(node_for(node, overlay))
        assert.is_not_nil(node_for(node, image))
    end)

    it("sizes FIT stack content after a childless painted background", function()
        local text = require("wibox.widget.textbox")("content")
        local paint = background(nil, "#000000aa")
        local l = stack(paint, text)
        local font = stub(awesome, "_clay_font", function() return 1 end)
        local node = wclay.compile({_attachment_fit = true, background_color = BG},
            l, context, 100, 100)
        font:revert()
        local content = assert(node_for(node, text))
        assert.is_nil(content.float)
        assert.is_equal("content", content.children[1].text)
        assert.is_equal("fit", node.w)
        assert.is_equal("fit", node.h)
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
            assert.is_equal("leaf", child.name)
        end

        local _, leaves = compile(BG, margin(stack(a, b), 1, 1, 1, 1), BG)

        assert.is_equal(0, #leaves)
    end)

    it("insets content and keeps later attachment offsets", function()
        local l = stack(leaf_widget(10, 5), leaf_widget(20, 5))

        l.spacing = 3
        l.vertical_offset = 1

        local node = layout_node(l)

        assert.is_same({ 3, 0, 3, 0 }, node.pad)
        assert.is_nil(node.children[1].x)
        assert.is_same({ 3, 4 }, {node.children[2].x, node.children[2].y})
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
        l.vertical_offset = -2
        local node = layout_node(l)
        for _, child in ipairs(node.children) do
            assert.is_equal(child.float and 0 or nil, child.y)
            assert.is_nil(child.pad)
        end
        assert.stub(warning).was_called(1)
        warning:revert()
        warning = stub(gdebug, "print_warning")
        l.vertical_offset = 1.5
        node = layout_node(l)
        assert.is_nil(node.children[1].y)
        assert.is_equal(2, node.children[2].y)
        assert.stub(warning).was_called(0)
        warning:revert()

        l = stack(leaf_widget(10, 5))
        rawset(l, "layout", function(self, ...) return stack.layout(self, ...) end)
        assert.is_nil(layout_node(l))
    end)
end)

describe("wibox.clay place", function()
    local place = require("wibox.container.place")

    it("invalidates cached float positions when the stack offsets change", function()
        local a, b = place(leaf_widget(10, 20)), leaf_widget(20, 30)
        local stack = require("wibox.layout.stack")(a, b)
        local host = {background_color = BG}
        local context = {}
        wclay.compile(host, stack, context, 200, 100)
        stack.vertical_offset = 7
        local tree = wclay.compile(host, stack, context, 200, 100)
        assert.is_equal(7, node_for(tree, b).y)
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
    it("declares spacing", function()
        local ratio = require("wibox.layout.ratio")
        local l = ratio.horizontal(leaf_widget(), leaf_widget())
        local warning = stub(gdebug, "print_warning")
        l.spacing = 5
        assert.is_equal(5, layout_node(l).gap)
        assert.stub(warning).was_not_called()
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

    it("rounds margins, fills a gradient color and ignores a surface", function()
        local w = margin(leaf_widget(), 1.5, 1.5, 1.5, 1.5)
        local warning = stub(gdebug, "print_warning")
        assert.is_same({ 2, 2, 2, 2 }, layout_node(w).pad)
        w.color = GRADIENT
        local node = layout_node(w)
        assert.is_nil(node.border)
        assert.is_same({ 0, 0, 10, 0 }, node.children[1].fill.linear)
        assert.stub(warning).was_called(0)
        w.color = surface_pattern()
        node = layout_node(w)
        assert.is_nil(node.border)
        assert.is_equal(1, #node.children)
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

describe("wibox.clay arcchart", function()
    it("keeps asymmetric padding, fills gradients and omits transparent strokes and arcs", function()
        local arcchart = require("wibox.container.arcchart")
        local w = arcchart()
        w.values, w.colors = { 1, 1 }, { "#ff0000", "#00ff00" }
        w.thickness, w.border_width = 6, 2
        w.paddings = { left = 4, right = 0, top = 2, bottom = 2 }
        w.bg = "#0000ff"
        local warning = stub(gdebug, "print_warning")
        local node = w._clay.describe(w, BG, nil, nil, DEFINITE)
        assert.is_same({ 14, 10, 12, 12 }, node.pad)
        assert.stub(warning).was_called(0)
        w.bg = GRADIENT
        local ring = w._clay.describe(w, BG, nil, nil, DEFINITE).specs[2]
        assert.is_nil(ring.stroke)
        assert.is_same({ 5, 5, 15, 5 }, ring.fill.linear)
        w.colors = { "#ff0000", GRADIENT }
        assert.is_same({ 1, 1, 11, 1 }, w._clay.describe(w, BG, nil, nil, DEFINITE).specs[4].fill.linear)
        assert.stub(warning).was_called(0)
        w.border_color = GRADIENT
        assert.is_equal(#node.specs - 1, #w._clay.describe(w, BG, nil, nil, DEFINITE).specs)
        assert.stub(warning).was_called(1)
        w.colors = { "#ff0000", surface_pattern() }
        assert.is_equal(#node.specs - 2, #w._clay.describe(w, BG, nil, nil, DEFINITE).specs)
        assert.stub(warning).was_called(2)
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
    it("insets a path border and pads its child for the inner strategy", function()
        local w = background(leaf_widget(), BG)
        w:set_shape(function(cr, width, height, radius)
            gshape.partially_rounded_rect(cr, width, height, true, false, false, true,
                radius or 8)
        end, 6)
        w.border_width, w.border_color, w.border_strategy = 2, "#0000ff", "inner"
        local node = layout_node(w)
        assert.is_nil(node.radius)
        assert.is_nil(node.border)
        assert.is_nil(node.bw)
        assert.is_same(BG_RGBA, node.fill)
        assert.is_same({ 0, 0, 1, 1 }, node.stroke)
        assert.is_equal(2, node.stroke_width)
        assert.is_same({ 2, 2, 2, 2 }, node.pad)
        assert.is_equal(1, #node.children)
        assert.is_same(wclay.shape_ops(gshape.partially_rounded_rect, 38, 18, 1, 1,
            true, false, false, true, 6), node.shape(40, 20))
    end)

    it("fills a nonrectangular background with a gradient", function()
        local w = background(leaf_widget(), "linear:0,0:40,0:0,#000000:1,#ffffff",
            gshape.circle)
        local node = layout_node(w)
        assert.is_nil(node.radius)
        assert.is_nil(node.bg)
        assert.is_equal(2, #node.fill.stops)
        assert.is_same(wclay.shape_ops(gshape.circle, 40, 20, 0, 0), node.shape(40, 20))
    end)

    it("rejects a function bgimage at the setter and keeps the child", function()
        local w = background(leaf_widget(), BG)
        local warning = stub(gdebug, "print_warning")
        w.bgimage = function() end
        assert.is_nil(w.bgimage)
        assert.stub(warning).was_called(1)
        assert.stub(warning).was_called_with(
            "wibox.container.background: bgimage functions are not drawn")
        warning:clear()
        local node = layout_node(w)
        assert.is_nil(node.image)
        assert.is_equal(1, #node.children)
        assert.is_nil(node.children[1].image)
        assert.is_equal("leaf", node.children[1].name)
        assert.stub(warning).was_called(0)
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

    it("declares a clip path, ignores fit policy and describes an SVG handle as a vector", function()
        local imagebox = require("wibox.widget.imagebox")
        local cairo = require("lgi").cairo
        local src = cairo.ImageSurface(cairo.Format.ARGB32, 20, 10)
        local w = imagebox(src, true, gshape.circle)
        local warning = stub(gdebug, "print_warning")
        local node = w._clay.describe(w)
        assert.is_equal(2, node.specs[1].aspect)
        assert.is_not_nil(node.specs[1].image)
        assert.is_true(node.clip)
        assert.is_nil(node.fill)
        assert.is_nil(node.stroke)
        assert.is_same(wclay.shape_ops(gshape.circle, 40, 40), node.shape(40, 40))
        assert.stub(warning).was_not_called()
        w = imagebox(src)
        w.horizontal_fit_policy = "fit"
        assert.is_equal(2, w._clay.describe(w).specs[1].aspect)
        assert.stub(warning).was_called(1)
        local handle = require("lgi").Rsvg.Handle.new_from_data(
            "<svg xmlns='http://www.w3.org/2000/svg' width='16' height='16'>"
                .. "<circle cx='8' cy='8' r='8'/></svg>")
        w = imagebox()
        w.image = handle
        local spec = w._clay.describe(w).specs[1]
        assert.is_true(spec.vector)
        assert.is_equal(handle._native, spec.image)
        assert.is_equal(16, spec.image_width)
        assert.is_equal(16, spec.image_height)
        assert.is_equal(1, spec.aspect)
        assert.stub(warning).was_called(1)
        warning:revert()
    end)
end)

describe("wibox.clay progressbar", function()
    it("ignores ticks, rounds margins, fills a gradient bar and omits a surface bar", function()
        local w = require("wibox.widget.progressbar")()
        w.ticks, w.margins, w.value = true, 1.5, 0.5
        local warning = stub(gdebug, "print_warning")
        local node = w._clay.describe(w)
        assert.is_same({ 2, 2, 2, 2 }, node.pad)
        assert.stub(warning).was_called(1)
        w.color = GRADIENT
        local bar = w._clay.describe(w).specs[1].children[1]
        assert.is_nil(bar.bg)
        assert.is_same({ 0, 0, 10, 0 }, bar.fill.linear)
        assert.is_function(bar.shape)
        assert.stub(warning).was_called(1)
        w.color = surface_pattern()
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
    it("rounds height, fills a gradient handle and uses the bar color for a surface", function()
        local w = require("wibox.widget.slider")()
        w.bar_height, w.bar_color = 4.4, "#0000ff"
        local warning = stub(gdebug, "print_warning")
        local node = w._clay.describe(w)
        assert.is_equal(4, node.specs[1].children[1].h)
        w.handle_color = GRADIENT
        assert.is_same({ 0, 0, 10, 0 }, w._clay.describe(w).specs[2].fill.linear)
        assert.stub(warning).was_not_called()
        w.handle_color = surface_pattern()
        assert.is_same({ 0, 0, 1, 1 }, w._clay.describe(w).specs[2].fill)
        assert.stub(warning).was_called(1)
        w.handle_color, w.handle_border_width, w.bar_color = nil, 1, GRADIENT
        assert.is_nil(w._clay.describe(w).specs[2].stroke)
        assert.stub(warning).was_called(2)
        assert.matches("slider bar_color is not solid and the handle border is not drawn",
            warning.calls[2].vals[1], 1, true)
        warning:revert()
    end)
end)

describe("wibox.clay checkbox", function()
    it("fills a gradient check at the content corner and uses the main color for a surface", function()
        local w = require("wibox.widget.checkbox")()
        w.checked, w.color = true, "#0000ff"
        w.check_color = GRADIENT
        local warning = stub(gdebug, "print_warning")
        -- The content corner is half the 1 pixel border plus the 1 pixel padding.
        assert.is_same({ 1.5, 1.5, 11.5, 1.5 },
            w._clay.describe(w, nil, nil, nil, DEFINITE).specs[2].fill.linear)
        assert.stub(warning).was_not_called()
        w.check_color = surface_pattern()
        assert.is_same({ 0, 0, 1, 1 }, w._clay.describe(w, nil, nil, nil, DEFINITE).specs[2].fill)
        assert.stub(warning).was_called(1)
        warning:revert()
    end)
end)

describe("wibox.clay graph", function()
    it("rounds the border, fills a gradient data group and omits a surface one", function()
        local w = require("wibox.widget.graph")()
        w.border_width, w.border_color, w.color = 1.4, "#0000ff", "#ff0000"
        w:add_value(0.5)
        local warning = stub(gdebug, "print_warning")
        local node = w._clay.describe(w)
        assert.is_same({ 1, 1, 1, 1 }, node.bw)
        assert.is_equal(1, #node.specs)
        assert.stub(warning).was_called(0)
        w.color = GRADIENT
        assert.is_same({ 1, 1, 11, 1 }, w._clay.describe(w).specs[1].fill.linear)
        assert.stub(warning).was_called(0)
        w.color = surface_pattern()
        assert.is_equal(0, #w._clay.describe(w).specs)
        assert.stub(warning).was_called(1)
        warning:revert()
    end)
end)

describe("wibox.clay piechart", function()
    it("fills a gradient sector and omits a surface one", function()
        local w = require("wibox.widget.piechart")()
        w.data_list, w.display_labels = { { "a", 1 }, { "b", 1 } }, false
        w.colors, w.border_color = { "#ff0000", GRADIENT }, "#000000"
        local warning = stub(gdebug, "print_warning")
        assert.is_same({ 0, 0, 10, 0 }, w._clay.describe(w, BG).specs[2].fill.linear)
        assert.stub(warning).was_not_called()
        w.colors = { "#ff0000", surface_pattern() }
        assert.is_equal(1, #w._clay.describe(w, BG).specs)
        assert.stub(warning).was_called(1)
        warning:revert()
    end)
end)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80


describe("wibox.clay authored square bounds", function()
    local function square_node(kind, width, height, host)
        local w = kind == "checkbox" and require("wibox.widget.checkbox")()
            or require("wibox.container.arcchart")(leaf_widget(12, 8))
        local tree = wclay.compile(host or {background_color=BG}, fixed.horizontal(w),
            context, width, height, {w = "user", h = "user"})
        return assert(node_for(tree, w)), w
    end

    for _, kind in ipairs {"checkbox", "arcchart"} do
        it("declares " .. kind .. " at its authored bound", function()
            -- In a row the width is unbounded; the height bound is the side.
            for _, offer in ipairs {{240,100}, {40,200}, {301,77}} do
                local node, w = square_node(kind, offer[1], offer[2])
                if kind == "arcchart" then
                    -- The content square is the bound less the padding.
                    local square = node.children[1]
                    assert.is_equal(offer[2] - 10, square.w)
                    assert.is_equal(offer[2] - 10, square.h)
                    assert.is_equal("user", square.wsrc)
                    assert.is_equal("user", square.hsrc)
                    assert(node_for(node, w:get_children()[1]), "the real child lost its binding")
                else
                    assert.is_equal(offer[2], node.w)
                    assert.is_equal("user", node.wsrc)
                    assert.is_equal("grow", node.h)
                    assert.is_equal(offer[2], node.hmin)
                    assert.is_equal("user", node.hsrc)
                end
            end
        end)

        it("refuses " .. kind .. " without a definite axis", function()
            local message
            local warning = stub(gdebug, "print_warning", function(text) message = text end)
            local w = kind == "checkbox" and require("wibox.widget.checkbox")()
                or require("wibox.container.arcchart")(leaf_widget(12, 8))
            local tree = wclay.compile({background_color=BG, _attachment_fit=true},
                fixed.horizontal(w), context, 1, 1)
            assert.is_nil(node_for(tree, w))
            assert.stub(warning).was_called(1)
            assert.matches("no definite axis", message, 1, true)
            assert.matches("and is left out of the tree", message, 1, true)
            warning:revert()
        end)

        it("preserves " .. kind .. " forced axes", function()
            for _, axes in ipairs {{60,false}, {false,30}, {60,30}} do
                local w = kind == "checkbox" and require("wibox.widget.checkbox")()
                    or require("wibox.container.arcchart")()
                w.forced_width, w.forced_height = axes[1] or nil, axes[2] or nil
                local node = fixed_node(w)
                assert.is_equal("grow", node.h)
                if kind == "checkbox" then
                    -- A forced axis or the 100 high row bounds the square.
                    local side = math.min(axes[1] or 100, axes[2] or 100)
                    assert.is_equal(axes[1] or side, node.w)
                    assert.is_equal(axes[2] or side, node.hmin)
                else
                    assert.is_equal(axes[1] or "fit", node.w or "fit")
                    assert.is_equal(axes[2] or nil, node.hmin)
                end
            end
        end)
    end

    it("uses either single definite axis symmetrically", function()
        for _, forced in ipairs {{80,false}, {false,80}} do
            local w = require("wibox.container.arcchart")()
            w.forced_width, w.forced_height = forced[1] or nil, forced[2] or nil
            local tree = wclay.compile({background_color=BG, _attachment_fit=true},
                fixed.horizontal(w), context, 1, 1)
            local square = assert(node_for(tree, w)).children[1]
            assert.is_equal(70, square.w)
            assert.is_equal(70, square.h)
        end
    end)
end)


describe("wibox.clay popup minimum allocation", function()
    it("keeps minimum constraints and original GROW bindings across cache reuse", function()
        local root, child = base.make_widget(), base.make_widget()
        wclay.describe_widget(child, function() return {bg=BG_RGBA} end, "content")
        wclay.describe_widget(root, function()
            return {fit=true, wmin=300, hmin=160,
                specs={{widget=child,w="grow",h="grow"}, {widget=leaf_widget(1,1)}}}
        end, "bounded-popup")
        local host, occurrence = {background_color=BG}, nil
        for _, offer in ipairs {{640,300},{640,300},{320,800},{320,800}} do
            local tree = wclay.compile(host,root,context,offer[1],offer[2])
            local node = assert(node_for(tree,child))
            assert.is_equal("grow",node.w)
            assert.is_equal("grow",node.h)
            assert.is_equal(300, tree.wmin)
            assert.is_equal(160, tree.hmin)
            if occurrence then assert.is_equal(occurrence,node.occurrence) end
            occurrence=node.occurrence
        end
    end)
end)


describe("wibox.clay textbox markup", function()
    local textbox = require("wibox.widget.textbox")
    local old_font, warning
    before_each(function()
        old_font = awesome._clay_font
        awesome._clay_font = function() return 1 end
        warning = stub(gdebug, "print_warning")
    end)
    after_each(function()
        awesome._clay_font = old_font
        warning:revert()
    end)
    it("retains two colour spans without a warning", function()
        local w = textbox("<span color='#ff0000'>red</span> <span color='#0000ff'>blue</span>")
        w.font = "sans 10"
        local spec = textbox._clay.describe(w, "#ffffff", {context=context}).specs[1]
        assert.is_same({0,3,0,1,0,0,1, 4,8,0,0,0,1,1}, spec.attrs)
        assert.stub(warning).was_called(0)
    end)
    it("warns once for a font change", function()
        local w = textbox("<b>x</b> y")
        w.font = "sans 10"
        textbox._clay.describe(w, "#ffffff", {context=context})
        textbox._clay.describe(w, "#ffffff", {context=context})
        assert.stub(warning).was_called(1)
    end)
end)

describe("wibox.clay authored properties", function()
    it("inserts distinct spacing widget specs in fixed and ratio layouts", function()
        local warning = stub(gdebug, "print_warning")
        for _, module in ipairs {fixed, require("wibox.layout.ratio")} do
            local l = module.horizontal(leaf_widget(), leaf_widget(), leaf_widget())
            local spacer = leaf_widget(6, 5)
            l.spacing, l.spacing_widget = 6, spacer
            local node = l._clay.describe(l)
            assert.is_equal(0, node.gap)
            assert.is_equal(5, #node.specs)
            assert.is_equal(spacer, node.specs[2].widget)
            assert.is_equal(spacer, node.specs[4].widget)
            assert.is_not_equal(node.specs[2], node.specs[4])
            assert.is_equal(6, node.specs[2].w)
            assert.is_equal("grow", node.specs[2].h)
        end
        assert.stub(warning).was_not_called()
        warning:revert()
    end)

    it("declares progressbar bar borders", function()
        local warning = stub(gdebug, "print_warning")
        local w = require("wibox.widget.progressbar")()
        w.value, w.bar_shape = 0.5, gshape.rounded_rect
        w.bar_border_width, w.bar_border_color = 2, "#00ff00"
        local bar = w._clay.describe(w).specs[1].children[1]
        assert.is_same({0, 1, 0, 1}, bar.border)
        assert.is_same({2, 2, 2, 2}, bar.bw)
        assert.stub(warning).was_not_called()
        warning:revert()
    end)

    it("declares tray backgrounds and floating overlays", function()
        local beautiful = require("beautiful")
        local warning = stub(gdebug, "print_warning")
        local surface = require("lgi").cairo.ImageSurface(require("lgi").cairo.Format.ARGB32,16,16)
        local item = {status="NeedsAttention", overlay_icon=surface._native, id="clay-test"}
        function item:_icon_surface() return surface._native, 16, 16 end
        local w = {_private={item=item, forced_size=24}}
        beautiful.systray_icon_style = {[item.id]={urgent_bg="#00ff00", hover_bg="#ff0000", overlay_bg="#0000ff", overlay_size=0.5}}
        local node = wclay.systray_icon(w)
        assert.is_same({0,1,0,1}, node.bg)
        local overlay = node.specs[2]
        assert.is_true(overlay.float)
        assert.is_equal(8, overlay.parent)
        assert.is_equal(8, overlay.own)
        assert.is_equal(12, overlay.w)
        assert.is_equal("theme", overlay.wsrc)
        assert.is_equal("user", node.wsrc)
        assert.is_equal("grow", overlay.children[1].w)
        w._private.is_hovered = true
        assert.is_same({0,1,0,1}, wclay.systray_icon(w).bg)
        item.status = "Active"
        assert.is_same({1,0,0,1}, wclay.systray_icon(w).bg)
        local style = beautiful.systray_icon_style[item.id]
        style.overlay_size = 10
        assert.is_equal(10, wclay.systray_icon(w).specs[2].w)
        style.overlay_size = 0.33
        assert.is_equal(8, wclay.systray_icon(w).specs[2].w)
        style.overlay_size = 0.1
        assert.is_equal(2, wclay.systray_icon(w).specs[2].w)
        assert.stub(warning).was_not_called()
        beautiful.systray_icon_style = nil
        warning:revert()
    end)

    it("caps image scaling with source dimensions and authored maxima", function()
        local warning = stub(gdebug, "print_warning")
        local cairo = require("lgi").cairo
        local w = require("wibox.widget.imagebox")(cairo.ImageSurface(cairo.Format.ARGB32,16,16))
        w.max_scaling_factor = 2
        local image = w._clay.describe(w).specs[1]
        assert.is_equal(32, image.wmax)
        assert.is_equal(32, image.hmax)
        w.forced_width = 24
        assert.is_equal(24, w._clay.describe(w).specs[1].w)
        w.forced_width = 40
        assert.is_equal(32, w._clay.describe(w).specs[1].w)
        assert.stub(warning).was_not_called()
        warning:revert()
    end)
end)

describe("wibox.clay retired properties", function()
    it("warns once that each is ignored and reads nil", function()
        local retired = {
            {require("wibox.layout.stack")(), {"horizontal_offset"}},
            {require("wibox.layout.grid")(), {"minimum_column_width", "superpose"}},
            {require("wibox.layout.ratio").horizontal(), {"inner_fill_strategy"}},
            {background(), {"stretch_horizontally", "stretch_vertically"}},
            {require("wibox.container.radialprogressbar")(), {"paddings"}},
            {require("wibox.container.tile")(), {"horizontal_crop", "vertical_crop"}},
            {require("wibox.widget.imagebox")(), {"auto_dpi", "source_width"}},
            {require("wibox.widget.progressbar")(), {"ticks_gap"}},
            -- The slider takes each name in its constructor table first.
            {require("wibox.widget.slider"), {"bar_border_color", "bar_border_width", "handle_margins"}},
            {require("wibox.widget.calendar").month({year = 2026, month = 10}),
                {"empty_cell_mode", "empty_color", "empty_widget"}},
            {require("wibox.widget.checkbox")(), {"check_border_color", "check_border_width", "check_shape"}},
        }
        for _, case in ipairs(retired) do
            for _, name in ipairs(case[2]) do
                local warning = stub(gdebug, "print_warning")
                local w = case[1]
                if not w.is_widget then
                    w = w { [name] = 1, bar_height = 4 }
                    assert.is_nil(w._private[name])
                    assert.is_equal(4, w._private.bar_height)
                else
                    w[name] = 1
                end
                w[name] = 2
                assert.stub(warning).was_called(1)
                assert.matches(" " .. name .. " is ignored$", warning.calls[1].refs[1])
                assert.is_nil(w[name])
                warning:revert()
            end
        end
    end)
end)
