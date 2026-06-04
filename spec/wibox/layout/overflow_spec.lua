---------------------------------------------------------------------------
-- @author Lucas Schwiderski
---------------------------------------------------------------------------

local overflow = require("wibox.layout.overflow")
local base = require("wibox.widget.base")
local utils = require("wibox.test_utils")
local p = require("wibox.widget.base").place_widget_at

describe("wibox.layout.overflow", function()
    local layout

    before_each(function()
        layout = overflow.vertical()
    end)

    it("empty layout fit", function()
        assert.widget_fit(layout, { 10, 10 }, { 0, 0 })
    end)

    it("empty layout layout", function()
        assert.widget_layout(layout, { 0, 0 }, {})
    end)

    describe("with widgets that fit", function()
        local first, second, third

        before_each(function()
            first = utils.widget_stub(10, 10)
            second = utils.widget_stub(15, 15)
            third = utils.widget_stub(10, 10)

            layout:add(first, second, third)
        end)

        it("fit without overflow", function()
            assert.widget_fit(layout, { 100, 100 }, { 15, 35 })
        end)

        it("layout without overflow", function()
            assert.widget_layout(layout, { 100, 100 }, {
                p(first,  0,  0, 100, 10),
                p(second, 0, 10, 100, 15),
                p(third,  0, 25, 100, 10),
            })
        end)
    end)

    describe("with widgets that overflow", function()
        local first, second, third

        before_each(function()
            first = utils.widget_stub(10, 20)
            second = utils.widget_stub(10, 20)
            third = utils.widget_stub(10, 20)

            layout:add(first, second, third)
        end)

        it("fit is clamped but includes scrollbar width", function()
            -- Total height = 60, available = 50, so scrollbar is needed.
            -- scrollbar_width default = 5, so used_max = 10 + 5 = 15
            -- Height is clamped to available (50) by base.fit_widget
            assert.widget_fit(layout, { 100, 50 }, { 15, 50 })
        end)

        it("fit without scrollbar enabled", function()
            layout:set_scrollbar_enabled(false)
            -- No scrollbar, so used_max = 10 (max widget width)
            -- Height clamped to 50
            assert.widget_fit(layout, { 100, 50 }, { 10, 50 })
        end)
    end)

    describe("scrollbar properties", function()
        it("default scrollbar_enabled is true", function()
            assert.is_true(layout:get_scrollbar_enabled())
        end)

        it("set and get scrollbar_enabled", function()
            layout:set_scrollbar_enabled(false)
            assert.is_false(layout:get_scrollbar_enabled())
        end)

        it("default scrollbar_position is right for vertical", function()
            assert.is.equal("right", layout:get_scrollbar_position())
        end)

        it("default scrollbar_position is bottom for horizontal", function()
            local hlayout = overflow.horizontal()
            assert.is.equal("bottom", hlayout:get_scrollbar_position())
        end)

        it("set and get scrollbar_position", function()
            layout:set_scrollbar_position("left")
            assert.is.equal("left", layout:get_scrollbar_position())
        end)

        it("default scroll_factor is 0", function()
            assert.is.equal(0, layout:get_scroll_factor())
        end)
    end)

    describe("emitting signals", function()
        local layout_changed

        before_each(function()
            layout:connect_signal("widget::layout_changed", function()
                layout_changed = layout_changed + 1
            end)
            layout_changed = 0
        end)

        it("add", function()
            local w1, w2 = base.empty_widget(), base.empty_widget()
            assert.is.equal(0, layout_changed)
            layout:add(w1)
            assert.is.equal(1, layout_changed)
            layout:add(w2)
            assert.is.equal(2, layout_changed)
        end)

        it("reset", function()
            assert.is.equal(0, layout_changed)
            layout:add(base.make_widget())
            assert.is.equal(1, layout_changed)
            layout:reset()
            assert.is.equal(2, layout_changed)
        end)

        it("scrollbar_enabled", function()
            assert.is.equal(0, layout_changed)
            layout:set_scrollbar_enabled(true)
            assert.is.equal(0, layout_changed)
            layout:set_scrollbar_enabled(false)
            assert.is.equal(1, layout_changed)
        end)

        it("scrollbar_position", function()
            assert.is.equal(0, layout_changed)
            layout:set_scrollbar_position("right")
            assert.is.equal(0, layout_changed)
            layout:set_scrollbar_position("left")
            assert.is.equal(1, layout_changed)
        end)

        it("scrollbar_width", function()
            assert.is.equal(0, layout_changed)
            layout:set_scrollbar_width(5)
            assert.is.equal(0, layout_changed)
            layout:set_scrollbar_width(10)
            assert.is.equal(1, layout_changed)
        end)
    end)

    it("set_children", function()
        local w1, w2 = base.empty_widget(), base.empty_widget()

        assert.is.same({}, layout:get_children())

        layout:add(w1)
        assert.is.same({ w1 }, layout:get_children())

        layout:add(w2)
        assert.is.same({ w1, w2 }, layout:get_children())

        layout:reset()
        assert.is.same({}, layout:get_children())
    end)

    describe("horizontal", function()
        local hlayout

        before_each(function()
            hlayout = overflow.horizontal()
        end)

        it("empty layout fit", function()
            assert.widget_fit(hlayout, { 10, 10 }, { 0, 0 })
        end)

        it("fit without overflow", function()
            local first = utils.widget_stub(10, 10)
            local second = utils.widget_stub(15, 15)
            hlayout:add(first, second)
            assert.widget_fit(hlayout, { 100, 100 }, { 25, 15 })
        end)

        it("fit with overflow adds scrollbar height", function()
            local first = utils.widget_stub(30, 10)
            local second = utils.widget_stub(30, 10)
            hlayout:add(first, second)
            -- Total width = 60, available = 50, so scrollbar needed.
            -- scrollbar_width default = 5, so used_max = 10 + 5 = 15
            -- Width clamped to 50 by base.fit_widget
            assert.widget_fit(hlayout, { 50, 100 }, { 50, 15 })
        end)
    end)

    describe("with spacing", function()
        local first, second, third

        before_each(function()
            first = utils.widget_stub(10, 10)
            second = utils.widget_stub(15, 15)
            third = utils.widget_stub(10, 10)

            layout:add(first, second, third)
            layout:set_spacing(5)
        end)

        it("fit includes spacing in content size", function()
            -- Total = 10 + 15 + 10 + 5*2 = 45
            assert.widget_fit(layout, { 100, 100 }, { 15, 45 })
        end)

        it("fit with overflow includes spacing", function()
            -- Total = 45, available = 40, so scrollbar needed
            -- used_max = 15 + 5 (scrollbar) = 20
            -- Height clamped to 40 by base.fit_widget
            assert.widget_fit(layout, { 100, 40 }, { 20, 40 })
        end)
    end)

    it("fill_space defaults to true", function()
        local w = utils.widget_stub(10, 10)
        layout:add(w)
        -- With fill_space=true, widget gets full width
        local result = layout:layout({ "fake context" }, 100, 100)
        assert.is.equal(100, result[1]._width)
    end)
end)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
