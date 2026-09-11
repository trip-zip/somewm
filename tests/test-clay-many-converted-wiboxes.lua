-- Test: twelve converted wiboxes on one output, one of them an awful.menu
-- with twelve items, all draw through Clay at once.
--
-- Every converted drawin used to be a Clay clip element, and a Clay context
-- holds ten scroll containers (clay.h:2194), so the eleventh aborted the
-- compositor. Clipping is the renderer's now, so the count is bounded by
-- the element budget alone.
--
-- Run: make test-one TEST=tests/test-clay-many-converted-wiboxes.lua

local runner = require("_runner")
local capture = require("_widget_capture")
local awful = require("awful")
local wibox = require("wibox")

local s = screen[1]
local COUNT = 11
local boxes = {}
local menu

-- The dump's line for drawin d.
local function line(d)
    return awesome._clay_tree(s):match(string.format(
        "  drawin screen %d %dx%d%%+%d%%+%d [^\n]*", s.index,
        d.width, d.height, d.x, d.y))
end

local steps = {
    function(count)
        if count == 1 then
            for i = 1, COUNT do
                local b = wibox {
                    x = 10 + (i - 1) * 60, y = 100, width = 50, height = 30,
                    visible = true, screen = s, bg = "#101010",
                }
                b:setup {
                    widget = wibox.container.margin,
                    margins = 4,
                    capture.leaf_widget(math.huge, nil, "#ff0000"),
                }
                boxes[i] = b
            end
            local items = {}
            for i = 1, 12 do
                items[i] = { "item " .. i, function() end }
            end
            menu = awful.menu({ items = items,
                theme = { width = 120, height = 20 } })
            menu:show({ coords = { x = 10, y = 200 } })
            return nil
        end

        local converted = 0

        for _, b in ipairs(boxes) do
            local l = line(b.drawin)

            if l and l:find("converted", 1, true) then
                converted = converted + 1
            end
        end

        local ml = line(menu.wibox.drawin)

        if converted == COUNT and ml and ml:find("converted", 1, true) then
            io.stderr:write("[PASS] twelve converted wiboxes share one output\n")
            return true
        end
        assert(count < 40, string.format("%d of %d wiboxes converted, menu: %s",
            converted, COUNT, tostring(ml)))
    end,

    -- The pointer over an item's label is the menu's, glyphs included.
    -- Warped twice, since the hit test runs against the position before the
    -- move.
    function()
        local d = menu.wibox.drawin
        local x, y = d.x + 40, d.y + 10

        mouse.coords({ x = x, y = y })
        mouse.coords({ x = x, y = y })
        assert(mouse.object_under_pointer() == d,
            "the pointer over a label is not the menu's: "
            .. tostring(mouse.object_under_pointer()))
        menu:hide()
        for _, b in ipairs(boxes) do
            b.visible = false
        end
        return true
    end,
}

runner.run_steps(steps)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
