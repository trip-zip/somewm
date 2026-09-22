---------------------------------------------------------------------------
-- @author Uli Schlachter
-- @copyright 2014 Uli Schlachter
---------------------------------------------------------------------------

local fixed = require("wibox.layout.fixed")
local base = require("wibox.widget.base")

describe("wibox.layout.fixed", function()
    local layout
    before_each(function()
        layout = fixed.vertical()
    end)

    it("empty add", function()
        assert.has_error(function()
            layout:add()
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
            assert.is.equal(layout_changed, 0)
            layout:add(w1)
            assert.is.equal(layout_changed, 1)
            layout:add(w2)
            assert.is.equal(layout_changed, 2)
            layout:add(w2)
            assert.is.equal(layout_changed, 3)
        end)

        it("set_spacing", function()
            assert.is.equal(layout_changed, 0)
            layout:set_spacing(0)
            assert.is.equal(layout_changed, 0)
            layout:set_spacing(5)
            assert.is.equal(layout_changed, 1)
            layout:set_spacing(2)
            assert.is.equal(layout_changed, 2)
            layout:set_spacing(2)
            assert.is.equal(layout_changed, 2)
        end)

        it("reset", function()
            assert.is.equal(layout_changed, 0)
            layout:add(base.make_widget())
            assert.is.equal(layout_changed, 1)
            layout:reset()
            assert.is.equal(layout_changed, 2)
        end)

        it("fill_space", function()
            assert.is.equal(layout_changed, 0)
            layout:fill_space(false)
            assert.is.equal(layout_changed, 0)
            layout:fill_space(true)
            assert.is.equal(layout_changed, 1)
            layout:fill_space(true)
            assert.is.equal(layout_changed, 1)
            layout:fill_space(false)
            assert.is.equal(layout_changed, 2)
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

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
