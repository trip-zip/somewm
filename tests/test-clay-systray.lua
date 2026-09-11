---------------------------------------------------------------------------
-- Test: the systray and its icons convert
--
-- wibox.widget.systray is a fixed layout with padding and a least size,
-- and each systray_icon centers the item's icon in its square slot. A
-- converted tray holds one image element per icon, from the item's pixmap;
-- an urgent icon uses the same plain image (third_party/clay.h:414-416).
--
-- Run: make test-one TEST=tests/test-clay-systray.lua
---------------------------------------------------------------------------

local runner = require("_runner")
local capture = require("_widget_capture")
local beautiful = require("beautiful")
local wibox = require("wibox")

local s = screen[1]
local BX, BY, BW, BH = 0, 0, 400, 24
local cap = capture.new(s, BX, BY, BW, BH)
local bar, tray, items, converted_boxes

-- A solid ARGB32 pixmap of one color, in the network byte order the item
-- takes (StatusNotifierItem's).
local function pixmap(r, g, b, size)
    local px = string.char(0xff, r, g, b)

    return size, size, px:rep(size * size)
end

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
            beautiful.systray_paddings = 2
            items = { systray_item.register(), systray_item.register() }
            items[1]:set_icon_pixmap(pixmap(0xff, 0x00, 0x00, 16))
            items[2]:set_icon_pixmap(pixmap(0x00, 0xff, 0x00, 16))
            -- The host session's own tray items reach a nested compositor
            -- over the shared bus; a passive item is left out of the tray.
            for _, item in ipairs(systray_item.get_items()) do
                if item ~= items[1] and item ~= items[2] then
                    item.status = "Passive"
                end
            end
            tray = wibox.widget.systray()
            tray:_sync_items()
            bar = wibox {
                x = BX, y = BY, width = BW, height = BH, screen = s,
                bg = "#101010", visible = true,
            }
            bar:setup {
                layout = wibox.layout.fixed.horizontal,
                tray,
            }
            return nil
        end

        local head, list = nodes()

        if not head or (head:find("converted", 1, true) and #list == 0) then
            assert(count_ < 20, "the bar never reached the dump")
            return nil
        end
        assert(head:find("converted", 1, true), "the bar did not convert: " .. head)
        assert(count(list, "wibox.widget.systray", false) == 1,
            "the tray is not a converted element")
        assert(count(list, "wibox.widget.systray_icon", false) == 2,
            "expected two converted icons")
        assert(count(list, "image", true) == 2, "expected two image leaves")

        -- Each icon its base size square, 24, inside the 2px padding.
        local icons = {}
        for _, node in ipairs(list) do
            if node.class == "wibox.widget.systray_icon" then
                icons[#icons + 1] = node.box
            end
        end
        assert(icons[1].x == 2 and icons[1].width == 24 and icons[2].x == 26,
            string.format("icons at %d+%d and %d, want 2+24 and 26",
                icons[1].x, icons[1].width, icons[2].x))
        io.stderr:write("[PASS] the tray and its icons convert\n")
        return true
    end,

    -- The renderer draws the pixmaps, each centered in its slot.
    function(count_)
        local shot = cap:shot()
        local ok = pcall(function()
            cap:assert_pixel(shot, 14, 12, "#ff0000", "the first icon")
            cap:assert_pixel(shot, 38, 12, "#00ff00", "the second icon")
        end)

        if ok then
            converted_boxes = #awesome._test_widget_boxes(bar.drawin)
            io.stderr:write("[PASS] the renderer draws the icons\n")
            return true
        end
        assert(count_ < 20, "the icons were not drawn")
    end,

    -- An urgent item draws as the plain icon.
    function(count_)
        if count_ == 1 then
            items[2].status = "NeedsAttention"
            return nil
        end

        local _, list = nodes()

        if count(list, "wibox.widget.systray_icon", false) == 2 then
            assert(#awesome._test_widget_boxes(bar.drawin) == converted_boxes, "urgency changed the widget boxes")
            io.stderr:write("[PASS] an urgent icon draws as the plain icon\n")
            bar.visible = false
            return true
        end
        assert(count_ < 20, "the urgent icon did not convert")
    end,
}

runner.run_steps(steps)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
