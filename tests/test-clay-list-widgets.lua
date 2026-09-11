---------------------------------------------------------------------------
-- Test: the taglist and tasklist pass through to Clay
--
-- awful.widget.taglist and tasklist are wrappers around a base layout, so a
-- converted bar holds one element per tag or client below them rather than
-- one image leaf for the whole list. The items are built from the widget
-- template, so the tag buttons on each item have to keep working through
-- find_widgets over Clay's boxes. A tasklist item's `icon_role` may be an
-- awful.widget.clienticon, as the bundled config has it, which shows its
-- client's icon as an image element.
--
-- Run: make test-one TEST=tests/test-clay-list-widgets.lua
---------------------------------------------------------------------------

local runner = require("_runner")
local awful = require("awful")
local beautiful = require("beautiful")
local wibox = require("wibox")
local cairo = require("lgi").cairo

local s = screen[1]
local bar, taglist, tasklist

-- The tree nodes of the bar's dump block.
local function nodes()
    local d = bar.drawin
    local want = string.format("  drawin screen %d %dx%d+%d+%d ", s.index,
        d.width, d.height, d.x, d.y)
    local head, out = nil, {}

    for line in awesome._clay_tree(s):gmatch("[^\n]+") do
        if head then
            local indent, class = line:match("^    %x+ ( *)([%w_.-]+)")
            if not indent then
                break
            end
            out[#out + 1] = { depth = #indent / 2, class = class,
                image = line:find(" image ", 1, true) ~= nil, line = line }
        elseif line:sub(1, #want) == want then
            head = line
        end
    end
    return head, out
end

local function count(list, class, image)
    local n = 0
    for _, node in ipairs(list) do
        if node.class == class and node.image == image then
            n = n + 1
        end
    end
    return n
end

local steps = {
    function(count_)
        if count_ == 1 then
            -- The theme's tag squares reach each item as a background
            -- image, which keeps the item drawing itself; without them the
            -- template converts down to its textbox.
            beautiful.taglist_squares_sel = nil
            beautiful.taglist_squares_unsel = nil
            awful.tag.add("two", { screen = s })
            awful.tag.add("three", { screen = s })
            taglist = awful.widget.taglist {
                screen = s,
                filter = awful.widget.taglist.filter.all,
                buttons = { awful.button({}, 1, function(t) t:view_only() end) },
            }
            -- One task with an icon, from a source of the test's own.
            local task = { valid = true, name = "task",
                icon = cairo.ImageSurface(cairo.Format.ARGB32, 16, 16) }
            tasklist = awful.widget.tasklist {
                screen = s,
                filter = function() return true end,
                source = function() return { task } end,
                widget_template = {
                    {
                        {
                            { id = "icon_role", widget = awful.widget.clienticon },
                            id = "icon_margin_role",
                            margins = 4,
                            widget = wibox.container.margin,
                        },
                        { id = "text_role", widget = wibox.widget.textbox },
                        layout = wibox.layout.fixed.horizontal,
                    },
                    id = "background_role",
                    widget = wibox.container.background,
                },
            }
            bar = wibox {
                x = 0, y = 0, width = 400, height = 24, screen = s,
                bg = "#101010", visible = true,
            }
            bar:setup {
                layout = wibox.layout.fixed.horizontal,
                taglist,
                tasklist,
            }
            return nil
        end

        local head, list = nodes()

        if not head or (head:find("converted", 1, true) and #list == 0) then
            assert(count_ < 20, "the bar never reached the dump")
            return nil
        end
        assert(head:find("converted", 1, true), "the bar did not convert: " .. head)
        assert(count(list, "awful.widget.taglist", false) == 1,
            "the taglist is not a converted element")
        assert(count(list, "awful.widget.tasklist", false) == 1,
            "the tasklist is not a converted element")
        -- One item per tag and one per task: the template's background,
        -- down to its textbox, and the task's icon as an image element.
        assert(count(list, "wibox.container.background", false) == 4,
            "expected four converted items")
        assert(count(list, "wibox.widget.textbox", false) == 4,
            "expected four textboxes as text elements")
        assert(count(list, "awful.widget.clienticon", false) == 1
            and count(list, "image", true) == 1,
            "the task's clienticon is not an image element")
        io.stderr:write("[PASS] the lists pass through to their items\n")
        return true
    end,

    -- A press on the second tag's item reaches its buttons through Clay's
    -- boxes, and the update the tag change causes converts again.
    function(count_)
        if count_ == 1 then
            local _, list = nodes()
            local items = {}
            for _, node in ipairs(list) do
                if node.class == "wibox.container.background" and not node.image then
                    items[#items + 1] = tonumber(node.line:match("box (%d+),"))
                end
            end
            assert(#items == 4 and items[2] > items[1], "the items are not in a row")
            bar.drawin.drawable:emit_signal("button::press", items[2] + 2, 12, 1, {})
            bar.drawin.drawable:emit_signal("button::release", items[2] + 2, 12, 1, {})
            return nil
        end

        local two = s.tags[2]

        assert(two.selected, "the second tag was not selected by the press")

        local head = nodes()

        assert(head:find("converted", 1, true), "the bar stopped converting: " .. head)
        io.stderr:write("[PASS] a tag button works through Clay's boxes\n")
        bar.visible = false
        return true
    end,
}

runner.run_steps(steps)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
