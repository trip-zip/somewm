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

-- A widget the chain can never convert, so it always ends up on the leaf.
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
    local h = root and hierarchy.new({ dpi = 96 }, root, 100, 100,
        function() end, function() end, {})

    return wclay.compile(drawable, h)
end

describe("wibox.clay", function()
    it("refuses a drawable whose own background is not a solid color", function()
        assert.is_nil(compile(nil, margin(leaf_widget(), 1, 1, 1, 1), BG))
        assert.is_nil(compile(
            gcolor("linear:0,0:10,0:0,#000000:1,#ffffff"),
            margin(leaf_widget(), 1, 1, 1, 1), BG))
    end)

    it("refuses a drawable with a background image", function()
        local h = hierarchy.new({ dpi = 96 }, margin(leaf_widget(), 1, 1, 1, 1),
            100, 100, function() end, function() end, {})

        assert.is_nil(wclay.compile({
            background_color = BG,
            foreground_color = BG,
            background_image = "anything",
        }, h))
    end)

    it("refuses a tree whose root converts nothing", function()
        assert.is_nil(compile(BG, leaf_widget(), BG))
        assert.is_nil(compile(BG, nil, BG))
    end)

    it("maps margins onto padding", function()
        local w = leaf_widget()
        local chain, rest = compile(BG, margin(w, 1, 2, 3, 4), BG)

        assert.is_equal(3, #chain)
        assert.is_same(BG_RGBA, chain[1].bg)
        assert.is_same({ 1, 2, 3, 4 }, chain[2].pad)
        assert.is_nil(chain[2].border)
        assert.is_true(chain[3].raster)
        assert.is_equal(w, rest:get_widget())
    end)

    it("maps a margin color onto a border of the same widths", function()
        local chain = compile(BG,
            margin(leaf_widget(), 1, 2, 3, 4, "#ff0000"), BG)

        assert.is_same({ 1, 2, 3, 4 }, chain[2].pad)
        assert.is_same({ 1, 2, 3, 4 }, chain[2].bw)
        assert.is_same({ 1, 0, 0, 1 }, chain[2].border)
    end)

    it("maps a background color and a square border", function()
        local w = background(leaf_widget(), "#00ff00")

        w.border_width = 2
        w.border_color = "#0000ff"

        local chain = compile(BG, w, BG)

        assert.is_same({ 0, 1, 0, 1 }, chain[2].bg)
        assert.is_same({ 0, 0, 1, 1 }, chain[2].border)
        assert.is_same({ 2, 2, 2, 2 }, chain[2].bw)
        assert.is_equal(0, chain[2].radius)
        assert.is_nil(chain[2].pad)
    end)

    it("pads a background whose border strategy shrinks its child", function()
        local w = background(leaf_widget(), "#00ff00")

        w.border_width = 2
        w.border_color = "#0000ff"
        w.border_strategy = "inner"

        local chain = compile(BG, w, BG)

        assert.is_same({ 2, 2, 2, 2 }, chain[2].pad)
    end)

    it("maps a rounded rectangle onto a corner radius the leaf shares", function()
        local chain = compile(BG,
            background(leaf_widget(), "#00ff00", function(cr, cw, ch)
                return gshape.rounded_rect(cr, cw, ch)
            end), BG)

        -- An inline shape function is not gears.shape.rounded_rect, so it
        -- draws itself: nothing above the leaf converted.
        assert.is_nil(chain)

        local w = background(leaf_widget(), "#00ff00")

        w:set_shape(gshape.rounded_rect, 8)
        chain = compile(BG, w, BG)

        assert.is_equal(8, chain[2].radius)
        assert.is_equal(8, chain[3].radius)
        assert.is_true(chain[3].raster)
    end)

    it("keeps a rounded background off the chain once a box comes between", function()
        local w = background(leaf_widget(), "#00ff00")

        w:set_shape(gshape.rounded_rect, 8)

        local chain = compile(BG, margin(w, 5, 5, 5, 5), BG)

        -- The margin converts; the rounded background under it would clip its
        -- children to a box the leaf no longer shares, so it stops the walk.
        assert.is_equal(3, #chain)
        assert.is_same({ 5, 5, 5, 5 }, chain[2].pad)
        assert.is_equal(0, chain[3].radius)
    end)

    it("refuses a rounded background that also has a border", function()
        local w = background(leaf_widget(), "#00ff00")

        w:set_shape(gshape.rounded_rect, 8)
        w.border_width = 1
        w.border_color = "#0000ff"

        assert.is_nil(compile(BG, w, BG))
    end)

    it("converts a chain of containers down to the first it cannot", function()
        local w = leaf_widget()
        local stopper = constraint(margin(w, 2, 2, 2, 2))
        local chain, rest = compile(BG,
            background(margin(stopper, 4, 4, 4, 4), "#00ff00"), BG)

        -- background, margin, then the constraint stops the walk; the margin
        -- inside it stays on the leaf with everything below.
        assert.is_equal(4, #chain)
        assert.is_same({ 0, 1, 0, 1 }, chain[2].bg)
        assert.is_same({ 4, 4, 4, 4 }, chain[3].pad)
        assert.is_true(chain[4].raster)
        assert.is_equal(stopper, rest:get_widget())
    end)

    it("carries the innermost background foreground to the leaf", function()
        local fg = gcolor("#ff00ff")
        local w = background(leaf_widget(), "#00ff00")

        w.fg = fg

        local _, _, _, leaf_fg = compile(BG, w, BG)

        assert.is_equal(fg, leaf_fg)
    end)

    it("stops at a widget whose drawing the chain does not carry", function()
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

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
