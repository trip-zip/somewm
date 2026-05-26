---------------------------------------------------------------------------
-- Tests for the :layout_node builders used by the merged screen solve.
--
-- layout_node returns a somewm.layout node tree (containers + widget leaves)
-- mirroring each layout's :layout sizing, without solving. These tests assert
-- the returned tree SHAPE; they do not run the engine.
---------------------------------------------------------------------------

local base = require("wibox.widget.base")
local layout = require("somewm.layout")
local align = require("wibox.layout.align")
local fixed = require("wibox.layout.fixed")
local flex = require("wibox.layout.flex")
local stack = require("wibox.layout.stack")
local place = require("wibox.container.place")
local margin = require("wibox.container.margin")
local background = require("wibox.container.background")
local utils = require("wibox.test_utils")

local no_parent = base.no_parent_I_know_what_I_am_doing
local ctx = { "fake context" }

describe("wibox.widget.base.widget_to_node", function()
    it("wraps a leaf widget as a widget node", function()
        local w = utils.widget_stub(10, 10)
        local node = base.widget_to_node(no_parent, ctx, w, 100, 20)
        assert.are.equal("widget", node._type)
        assert.are.equal(w, node.widget)
    end)

    it("returns nil for an invisible widget", function()
        local w = utils.widget_stub(10, 10)
        w._private.visible = false
        assert.is_nil(base.widget_to_node(no_parent, ctx, w, 100, 20))
    end)

    it("merges parent props onto the node", function()
        local w = utils.widget_stub(10, 10)
        local node = base.widget_to_node(no_parent, ctx, w, 100, 20, { grow = true })
        assert.is_true(node.props.grow)
    end)

    it("expands a container that implements layout_node", function()
        local w = utils.widget_stub(10, 10)
        local l = fixed.horizontal(w)
        local node = base.widget_to_node(no_parent, ctx, l, 100, 20, { grow = true })
        assert.are.equal("container", node._type)
        assert.is_true(node.props.grow)
    end)
end)

describe("wibox.layout.fixed:layout_node", function()
    it("returns a row of widget leaves sized on the main axis", function()
        local a, b = utils.widget_stub(10, 10), utils.widget_stub(15, 10)
        local node = fixed.horizontal(a, b):layout_node(ctx, 100, 20)
        assert.are.equal("container", node._type)
        assert.are.equal("row", node.props.direction)
        assert.are.equal(2, #node.children)
        assert.are.equal(a, node.children[1].widget)
        assert.are.equal(10, node.children[1].props.width)
        assert.are.equal(15, node.children[2].props.width)
        -- cross axis (height) is left unset so it fills.
        assert.is_nil(node.children[1].props.height)
    end)

    it("uses spacing as the container gap", function()
        local a, b = utils.widget_stub(10, 10), utils.widget_stub(10, 10)
        local l = fixed.horizontal(a, b)
        l:set_spacing(5)
        assert.are.equal(5, l:layout_node(ctx, 100, 20).props.gap)
    end)

    it("grows the last child when fill_space is set", function()
        local a, b = utils.widget_stub(10, 10), utils.widget_stub(10, 10)
        local l = fixed.horizontal(a, b)
        l:fill_space(true)
        local node = l:layout_node(ctx, 100, 20)
        assert.is_true(node.children[2].props.grow)
    end)

    it("degrades (nil) for negative spacing with a spacing widget", function()
        local l = fixed.horizontal(utils.widget_stub(10, 10))
        l:set_spacing(-5)
        l:set_spacing_widget(utils.widget_stub(2, 2))
        assert.is_nil(l:layout_node(ctx, 100, 20))
    end)

    -- A spacing_widget is interleaved as one shared object, which the
    -- retained-render boxmap (keyed by widget) cannot disambiguate, so any
    -- interleaved spacing degrades to a single leaf (forest positions it).
    it("degrades (nil) for positive spacing with a spacing widget", function()
        local l = fixed.horizontal(utils.widget_stub(10, 10), utils.widget_stub(10, 10))
        l:set_spacing(5)
        l:set_spacing_widget(utils.widget_stub(2, 2))
        assert.is_nil(l:layout_node(ctx, 100, 20))
    end)
end)

describe("wibox.layout.align:layout_node", function()
    it("inside: outer slots fit, center grows", function()
        local a, b, c = utils.widget_stub(10, 10), utils.widget_stub(15, 10),
            utils.widget_stub(20, 10)
        local node = align.horizontal(a, b, c):layout_node(ctx, 100, 20)
        assert.are.equal("row", node.props.direction)
        assert.are.equal(3, #node.children)
        assert.are.equal(10, node.children[1].props.width)
        assert.is_false(node.children[1].props.grow)
        assert.is_true(node.children[2].props.grow)
        assert.are.equal(20, node.children[3].props.width)
    end)

    it("inside: empty center keeps a grow spacer when first and third are set", function()
        local a, c = utils.widget_stub(10, 10), utils.widget_stub(10, 10)
        local node = align.horizontal(a, nil, c):layout_node(ctx, 100, 20)
        assert.are.equal(3, #node.children)
        assert.are.equal("container", node.children[2]._type)
        assert.is_true(node.children[2].props.grow)
    end)

    it("outside: outer slots grow, center fits", function()
        local a, b, c = utils.widget_stub(10, 10), utils.widget_stub(15, 10),
            utils.widget_stub(10, 10)
        local l = align.horizontal(a, b, c)
        l:set_expand("outside")
        local node = l:layout_node(ctx, 100, 20)
        assert.is_true(node.children[1].props.grow)
        assert.are.equal(15, node.children[2].props.width)
        assert.is_true(node.children[3].props.grow)
    end)

    it("degrades (nil) for expand=none", function()
        local l = align.horizontal(utils.widget_stub(10, 10))
        l:set_expand("none")
        assert.is_nil(l:layout_node(ctx, 100, 20))
    end)
end)

describe("container :layout_node", function()
    it("margin wraps the child in a padded row", function()
        local w = utils.widget_stub(10, 10)
        local node = margin(w, 1, 2, 3, 4):layout_node(ctx, 100, 20)
        assert.are.equal("container", node._type)
        -- padding is {top, right, bottom, left}; constructor is (w, l, r, t, b).
        assert.are.same({ 3, 2, 4, 1 }, node.props.padding)
        assert.are.equal(1, #node.children)
        assert.are.equal(w, node.children[1].widget)
        assert.is_true(node.children[1].props.grow)
    end)

    it("background wraps the child in a row", function()
        local w = utils.widget_stub(10, 10)
        local node = background(w):layout_node(ctx, 100, 20)
        assert.are.equal("container", node._type)
        assert.are.equal(w, node.children[1].widget)
        assert.is_true(node.children[1].props.grow)
    end)

    it("empty container degrades to nil", function()
        assert.is_nil(margin():layout_node(ctx, 100, 20))
        assert.is_nil(background():layout_node(ctx, 100, 20))
    end)
end)

-- Retained-render contract: each :layout_node container tags its returned node
-- with props.widget == the container itself, so the merged solve returns the
-- container's box and compose_screen can key its child placements by it
-- (lua/awful/layout/clay/init.lua collect_placements).
describe(":layout_node tags the container widget", function()
    it("fixed", function()
        local l = fixed.horizontal(utils.widget_stub(10, 10))
        assert.are.equal(l, l:layout_node(ctx, 100, 20).props.widget)
    end)
    it("align", function()
        local l = align.horizontal(utils.widget_stub(10, 10), nil,
            utils.widget_stub(10, 10))
        assert.are.equal(l, l:layout_node(ctx, 100, 20).props.widget)
    end)
    it("margin", function()
        local l = margin(utils.widget_stub(10, 10))
        assert.are.equal(l, l:layout_node(ctx, 100, 20).props.widget)
    end)
    it("background", function()
        local l = background(utils.widget_stub(10, 10))
        assert.are.equal(l, l:layout_node(ctx, 100, 20).props.widget)
    end)
end)

-- flex inherits fixed:layout_node via gtable.crush but overrides :layout to
-- distribute space equally. It has no builder of its own, so the fixed guard
-- (self.layout ~= fixed.layout) degrades it to nil -- otherwise the merged solve
-- would lay it out as a fixed pack and the retained path would paint it wrong.
-- Regression for the stack-rooted wibar that rendered widgets crammed left.
describe("fixed subclass without its own builder degrades", function()
    it("flex -> nil", function()
        local l = flex.horizontal(utils.widget_stub(10, 10), utils.widget_stub(10, 10))
        assert.is_nil(l:layout_node(ctx, 100, 20))
    end)
end)

-- stack and place DO have their own :layout_node (overriding the inherited fixed
-- one), so a stack-rooted wibar expands into the merged solve.
describe("stack/place :layout_node", function()
    it("stack overlays its children (somewm.layout.stack), tagged with self", function()
        local a, b = utils.widget_stub(10, 10), utils.widget_stub(20, 20)
        local l = stack(a, b)
        local node = l:layout_node(ctx, 100, 20)
        assert.are.equal("container", node._type)
        assert.is_true(node.props._stack)
        assert.are.equal(l, node.props.widget)
        assert.are.equal(2, #node.children)
        assert.are.equal(a, node.children[1].widget)
    end)

    it("stack degrades to nil with a per-child offset", function()
        local l = stack(utils.widget_stub(10, 10))
        l:set_horizontal_offset(5)
        assert.is_nil(l:layout_node(ctx, 100, 20))
    end)

    -- place centers a child at its FIT size, which needs the final allocated
    -- width (not known at merged-build time), so it has no layout_node and
    -- degrades to a leaf -> widget_to_node returns a plain widget node and the
    -- forest centers it at apply time.
    it("place has no layout_node (degrades to a leaf)", function()
        local p = place(utils.widget_stub(10, 10))
        assert.is_nil(p.layout_node)
        local node = base.widget_to_node(no_parent, ctx, p, 100, 20)
        assert.are.equal("widget", node._type)
        assert.are.equal(p, node.widget)
    end)
end)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
