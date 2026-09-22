---------------------------------------------------------------------------
-- @author Uli Schlachter
-- @copyright 2014 Uli Schlachter
---------------------------------------------------------------------------

local align = require("wibox.layout.align")

describe("wibox.layout.align", function()
    local layout
    before_each(function()
        layout = align.vertical()
    end)

    describe("emitting signals", function()
        local layout, layout_changed
        before_each(function()
            layout = align.vertical()
            layout:connect_signal("widget::layout_changed", function()
                layout_changed = layout_changed + 1
            end)
            layout_changed = 0
        end)

        it("set first", function()
            local w1, w2 = {}, {}
            assert.is.equal(layout_changed, 0)
            layout:set_first(w1)
            assert.is.equal(layout_changed, 1)
            layout:set_first(w2)
            assert.is.equal(layout_changed, 2)
            layout:set_first(w2)
            assert.is.equal(layout_changed, 2)
        end)

        it("set second", function()
            local w1, w2 = {}, {}
            assert.is.equal(layout_changed, 0)
            layout:set_second(w1)
            assert.is.equal(layout_changed, 1)
            layout:set_second(w2)
            assert.is.equal(layout_changed, 2)
            layout:set_second(w2)
            assert.is.equal(layout_changed, 2)
        end)

        it("set third", function()
            local w1, w2 = {}, {}
            assert.is.equal(layout_changed, 0)
            layout:set_third(w1)
            assert.is.equal(layout_changed, 1)
            layout:set_third(w2)
            assert.is.equal(layout_changed, 2)
            layout:set_third(w2)
            assert.is.equal(layout_changed, 2)
        end)

        it("set again", function()
            local w1, w2, w3 = {}, {}, {}
            layout = align.vertical(w1, w2, w3)
            layout:connect_signal("widget::layout_changed", function()
                layout_changed = layout_changed + 1
            end)
            assert.is.equal(layout_changed, 0)
            layout:set_first(w1)
            layout:set_second(w2)
            layout:set_third(w3)
            assert.is.equal(layout_changed, 0)
        end)
    end)

    it("set_children", function()
        local w1, w2, w3 = { w1 = true }, { w2 = true }, { w3 = true }
        local layout = align.vertical()

        assert.is.same({}, layout:get_children())

        layout:set_second(w2)
        assert.is.same({ w2 }, layout:get_children())

        layout:set_first(w1)
        assert.is.same({ w1, w2 }, layout:get_children())

        layout:set_third(w3)
        assert.is.same({ w1, w2, w3 }, layout:get_children())

        layout:set_second(nil)
        assert.is.same({ w1, w3 }, layout:get_children())

        layout:reset()
        assert.is.same({}, layout:get_children())
    end)
end)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
