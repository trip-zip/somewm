---------------------------------------------------------------------------
-- @author Uli Schlachter
-- @copyright 2017 Uli Schlachter
---------------------------------------------------------------------------

local grid = require("wibox.layout.grid")
local base = require("wibox.widget.base")

describe("wibox.layout.grid", function()
    it("set_children", function()
        local layout = grid()
        local w1, w2 = base.empty_widget(), base.empty_widget()

        assert.is.same({}, layout:get_children())

        layout:add(w1)
        assert.is.same({ w1 }, layout:get_children())

        layout:add_widget_at(w2, 2, 2)
        assert.is.same({ w1, w2 }, layout:get_children())

        layout:add_widget_at(w1, 1, 2)
        assert.is.same({ w1, w2, w1 }, layout:get_children())

        layout:reset()
        assert.is.same({}, layout:get_children())
    end)
    for _, axis in ipairs { "row", "column" } do
        it("invalidates " .. axis .. " mutations and shrinks the last spanned track", function()
            local layout = grid()
            local widget = base.empty_widget()
            layout:add(widget)
            local changes = 0
            layout:connect_signal("widget::layout_changed", function() changes = changes + 1 end)
            layout["extend_" .. axis](layout, 1)
            local span = axis == "row" and "row_span" or "col_span"
            assert.equals(2, layout:get_widget_position(widget)[span])
            assert.equals(1, changes)
            layout["remove_" .. axis](layout, 2)
            assert.equals(1, layout:get_widget_position(widget)[span])
            assert.equals(2, changes)
            layout["insert_" .. axis](layout, 1)
            local coordinate = axis == "row" and "row" or "col"
            assert.equals(2, layout:get_widget_position(widget)[coordinate])
            assert.equals(3, changes)
            layout["remove_" .. axis](layout, 1)
            assert.equals(1, layout:get_widget_position(widget)[coordinate])
            assert.equals(4, changes)
        end)
    end

end)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
