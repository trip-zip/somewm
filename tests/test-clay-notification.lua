---------------------------------------------------------------------------
-- Test: a notification box converts to Clay declarations
--
-- naughty's default box is a constraint (the notification's maximum width)
-- around its background, margins and layouts, with the icon, title and
-- message as its leaves. The constraint is a Clay size limit, the icon an
-- image element and the texts text elements, so the message wraps where
-- Clay wraps it.
--
-- Run: make test-one TEST=tests/test-clay-notification.lua
---------------------------------------------------------------------------

local runner = require("_runner")
local naughty = require("naughty")
local beautiful = require("beautiful")
local cairo = require("lgi").cairo

local s = screen[1]
local notif

-- The bundled config's handler: naughty's own box.
naughty.connect_signal("request::display", function(n)
    require("naughty.layout.box") { notification = n }
end)

-- The notification's drawin, once naughty has made its box.
local function box_drawin()
    for _, d in ipairs(drawin.get()) do
        local wb = d.get_wibox and d.get_wibox()
        local w = wb and wb.widget

        if w and w.get_notification and w:get_notification() == notif then
            return d
        end
    end
end

-- The tree nodes of the box's dump block.
local function nodes(d)
    local want = string.format("  drawin screen %d %dx%d+%d+%d ", s.index,
        d.width, d.height, d.x, d.y)
    local head, out = nil, {}

    for line in awesome._clay_tree(s):gmatch("[^\n]+") do
        if head then
            local indent, class = line:match("^    %x+ ( *)([%w_.-]+)")
            if not indent then
                break
            end
            local x, y, w, h = line:match("box (%d+),(%d+) (%d+)x(%d+)")
            out[#out + 1] = { depth = #indent / 2, class = class, line = line,
                image = line:find(" image ", 1, true) ~= nil,
                box = x and { x = tonumber(x), y = tonumber(y),
                    width = tonumber(w), height = tonumber(h) } }
        elseif line:sub(1, #want) == want then
            head = line
        end
    end
    return head, out
end

local function first(list, class)
    for _, node in ipairs(list) do
        if node.class == class then
            return node
        end
    end
end

local steps = {
    function(count)
        if count == 1 then
            local icon = cairo.ImageSurface(cairo.Format.ARGB32, 64, 64)

            notif = naughty.notification {
                title = "Hello",
                message = "A message long enough to wrap inside the box's "
                    .. "maximum width, which is where Clay wraps it too, "
                    .. "and then some more words so that it surely does",
                icon = icon,
                timeout = 0,
            }
            return nil
        end

        local d = box_drawin()
        local head, list

        if d then
            head, list = nodes(d)
        end

        if not head or (head:find("converted", 1, true) and #list == 0) then
            assert(count < 20, "the box never reached the dump")
            return nil
        end
        assert(head:find("converted", 1, true), "the box did not convert: " .. head)

        local images = {}
        for _, node in ipairs(list) do
            if node.image then
                images[#images + 1] = node.class
            end
        end
        assert(#images == 1, "expected one notification icon image: " .. table.concat(images, ", "))

        local limit = beautiful.notification_max_width or 500
        local constraint = first(list, "wibox.container.constraint")

        assert(constraint and constraint.line:find("<=" .. limit .. " ", 1, true),
            "the constraint is not a size limit: " .. tostring(constraint and constraint.line))
        assert(d.width <= limit, "the box is wider than its limit")

        local texts = {}
        for _, node in ipairs(list) do
            if node.class == "text" then
                texts[#texts + 1] = node
            end
        end
        assert(#texts == 2, "expected the title and the message as text elements, got " .. #texts)
        assert(texts[1].line:find('"Hello"', 1, true), "the title is not the first text: " .. texts[1].line)
        assert(texts[2].box.height > texts[1].box.height,
            "the message did not wrap: " .. texts[2].line)

        local image = first(list, "image")

        assert(image and image.box.width == 48 and image.box.height == 48,
            "the icon is not a 48x48 image element: " .. tostring(image and image.line))
        io.stderr:write("[PASS] the notification box converts\n")
        notif:destroy()
        return true
    end,
}

runner.run_steps(steps)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
