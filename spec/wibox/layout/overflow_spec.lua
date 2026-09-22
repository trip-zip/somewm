---------------------------------------------------------------------------
-- @author Lucas Schwiderski
---------------------------------------------------------------------------

local overflow = require("wibox.layout.overflow")
local base = require("wibox.widget.base")

describe("wibox.layout.overflow", function()
    local layout

    before_each(function()
        layout = overflow.vertical()
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

end)
