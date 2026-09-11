---------------------------------------------------------------------------
-- A frame settles what it declares. Lua compiles inside the frame, and a
-- tree whose solved boxes change what it shows (a grid telling its rows, a
-- popup taking its content's size) declares once more in the same frame:
-- one synchronous frame leaves the scene final, and a second one mutates
-- nothing. A popup still knows its size before any frame.
---------------------------------------------------------------------------

local runner = require("_runner")
local awful = require("awful")
local wibox = require("wibox")

local s = screen[1]
local geo = s.geometry
local bar, popup

local function settled(what)
    local n = awesome._test_redeclare()
    assert(n == 0, what .. ": the settled frame mutated " .. n .. " nodes")
end

-- The boxes with the given height, in x order.
local function boxes_of_height(drawin, height)
    local out = {}
    for _, b in ipairs(awesome._test_widget_boxes(drawin)) do
        if b.height == height then out[#out + 1] = b end
    end
    table.sort(out, function(a, b) return a.x < b.x end)
    return out
end

local steps = {
    -- A homogeneous grid's columns take the widest cell: the first solve
    -- measures the cells, the grid tells its columns, and the frame solves
    -- again before it reconciles.
    function()
        local g = wibox.layout.grid()
        g.spacing = 5
        g:add_widget_at(wibox.widget { bg = "#ff0000", forced_width = 20, forced_height = 10,
            widget = wibox.container.background }, 1, 1)
        g:add_widget_at(wibox.widget { bg = "#00ff00", forced_width = 40, forced_height = 10,
            widget = wibox.container.background }, 1, 2)
        bar = wibox { x = geo.x + 100, y = geo.y + 100, width = 200, height = 100,
            screen = s, visible = true, bg = "#204080", widget = g }

        assert(awesome._test_redeclare() > 0, "the bar declared nothing")
        local cells = boxes_of_height(bar.drawin, 10)
        assert(#cells == 2, #cells .. " cells, expected 2")
        assert(cells[1].x == 0 and cells[1].width == 40,
            "the narrow cell is " .. cells[1].width .. " wide at " .. cells[1].x)
        assert(cells[2].x == 45 and cells[2].width == 40,
            "the wide cell is " .. cells[2].width .. " wide at " .. cells[2].x)
        settled("the grid")
        io.stderr:write("[PASS] a grid's told columns land in the frame that declares it\n")
        return true
    end,

    -- A placed popup sizes itself before any frame, and a content change
    -- resizes it in the frame that declares the new content.
    function()
        popup = awful.popup { widget = wibox.widget.textbox("short"),
            screen = s, placement = awful.placement.top_left, visible = true }
        local w, h = popup.width, popup.height

        assert(w > 1 and h > 1, "the popup has no size before its frame")
        awesome._test_redeclare()
        local root = awesome._test_widget_boxes(popup.drawin)[1]
        assert(root and root.width == w and root.height == h,
            "the frame solved the popup at another size")
        settled("the popup")

        popup.widget = wibox.widget.textbox("a longer text than before")
        assert(awesome._test_redeclare() > 0, "the new content declared nothing")
        assert(popup.width > w, "the popup did not grow with its content")
        root = awesome._test_widget_boxes(popup.drawin)[1]
        assert(root.width == popup.width and root.height == popup.height,
            "the popup's size and its solved root differ")
        settled("the resized popup")
        io.stderr:write("[PASS] a popup fits its content in the frame that declares it\n")
        return true
    end,

    function()
        bar.visible = false
        popup.visible = false
        return true
    end,
}

runner.run_steps(steps)
