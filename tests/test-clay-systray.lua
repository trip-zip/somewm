---------------------------------------------------------------------------
-- Test: the systray and its icons convert
--
-- wibox.widget.systray is a fixed layout with padding and a least size, and
-- it centers each systray_icon's square slot across its direction. An icon
-- fills that square, so the item's pixmap is the element: a converted tray
-- holds image elements for the icons and their overlays.
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
local bar, tray, items

local function hide_foreign()
    local changed = false
    for _, item in ipairs(systray_item.get_items()) do
        if item ~= items[1] and item ~= items[2] and item.status ~= "Passive" then
            item.status = "Passive"
            changed = true
        end
    end
    return changed
end

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
            local indent, name = line:match("^    %x+ ( *)([%w_.-]+)")
            if not indent then
                break
            end
            local x, y, w, h = line:match("box (%d+),(%d+) (%d+)x(%d+)")
            out[#out + 1] = { depth = #indent / 2, name = name, line = line,
                image = line:find(" image ", 1, true) ~= nil,
                box = x and { x = tonumber(x), y = tonumber(y),
                    width = tonumber(w), height = tonumber(h) } }
        elseif line:sub(1, #want) == want then
            head = line
        end
    end
    return head, out
end

local function count(list, name, image)
    local n = 0
    for _, node in ipairs(list) do
        if node.name == name and node.image == image then
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
            hide_foreign()
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

        if hide_foreign() then
            tray:_sync_items()
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
        -- Each icon fills its own square, so the image owns that slot and
        -- the widget around it is not declared.
        local lines = {}
        for _, node in ipairs(list) do
            lines[#lines + 1] = node.line
        end
        assert(count(list, "image", true) == 2,
            "expected two icon images, dump:\n" .. table.concat(lines, "\n"))
        assert(count(list, "wibox.widget.systray_icon", false) == 0,
            "an icon kept a container it fills")

        -- Each icon its base size square, 24, inside the 2px padding.
        local icons = {}
        for _, node in ipairs(list) do
            if node.image then
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
            io.stderr:write("[PASS] the renderer draws the icons\n")
            return true
        end
        assert(count_ < 20, "the icons were not drawn")
    end,

    function(count_)
        if hide_foreign() then
            tray:_sync_items()
            return nil
        end
        if count_ == 1 then
            items[2].status = "NeedsAttention"
            beautiful.systray_urgent_bg = "#0000ff"
            local transparent = string.char(0, 0, 0, 0)
            local green = string.char(255, 0, 255, 0)
            local row = transparent:rep(4) .. green:rep(8) .. transparent:rep(4)
            items[2]:set_icon_pixmap(16, 16, transparent:rep(64) .. row:rep(8) .. transparent:rep(64))
            return nil
        end

        local _, list = nodes()

        if count(list, "image", true) == 2 then
            cap:assert_pixel(cap:shot(), 26, 2, "#0000ff", "the urgent icon corner")
            io.stderr:write("[PASS] the urgent icon has its background\n")
            bar.visible = false
            return true
        end
        assert(count_ < 20, "the urgent icon did not convert")
    end,
    function(count_)
        if count_ == 1 then
            beautiful.systray_overlay_size = 0.5
            beautiful.systray_overlay_bg = "#ffff00"
            beautiful.systray_overlay_shape = "rect"
            items[1]:set_overlay_pixmap(pixmap(0x00, 0x00, 0xff, 16))
            bar.visible = true
            return nil
        end
        local _, list = nodes()
        local floating
        for _, node in ipairs(list) do
            if node.line:find(" attach PARENT ", 1, true) then floating = node end
        end
        assert(floating, "the overlay is not a floating child:\n" .. awesome._clay_tree(s))
        local target = floating.line:match(" target (%x+)")
        local parent
        for _, node in ipairs(list) do
            if node.line:match("^    (%x+)") == target then parent = node end
        end
        assert(parent and parent.name == "wibox.widget.systray_icon",
            "the overlay is not attached to its icon")
        local shot = cap:shot()
        cap:assert_pixel(shot, 20, 20, "#0000ff", "the overlay image")
        cap:assert_pixel(shot, 15, 20, "#ffff00", "the overlay padding")
        bar.visible = false
        io.stderr:write("[PASS] the floating overlay paints its image and background\n")
        return true
    end,
    -- The urgent item is items[2], at x 26 to 50. A new pixmap redraws it
    -- and leaves four transparent columns on each side, so x 27 and 48 at
    -- y 2 show the background: red leads blue at the left, blue at the right.
    function(count_)
        if count_ == 1 then
            beautiful.systray_urgent_bg = capture.gradient(0, 24)
            local transparent = string.char(0, 0, 0, 0)
            local magenta = string.char(255, 255, 0, 255)
            local row = transparent:rep(4) .. magenta:rep(8) .. transparent:rep(4)
            items[2]:set_icon_pixmap(16, 16, transparent:rep(64) .. row:rep(8) .. transparent:rep(64))
            bar.visible = true
            return nil
        end
        if hide_foreign() then
            tray:_sync_items()
            return nil
        end
        local line = capture.dump_line(s, capture.gradient_record(0, 0, 24))
        local shot = cap:shot()
        local lr, _, lb = cap:pixel(shot, 27, 2)
        local rr, _, rb = cap:pixel(shot, 48, 2)
        if not (line and lr > lb and rr < rb) then
            assert(count_ < 20, "the gradient urgent background never drew: " .. awesome._clay_tree(s))
            return nil
        end
        assert(line:find("wibox.widget.systray_icon", 1, true), "the fill is not on the urgent item: " .. line)
        bar.visible = false
        io.stderr:write("[PASS] a gradient systray_urgent_bg draws red to blue across the urgent item\n")
        return true
    end,
    -- The overlay is 12 wide at x 14 to 26 of items[1] with 2 of padding;
    -- a new overlay pixmap redraws the icon. x 15 and 24 at y 20 are padding:
    -- red leads blue at the left, blue at the right.
    function(count_)
        if count_ == 1 then
            beautiful.systray_overlay_bg = capture.gradient(0, 12)
            items[1]:set_overlay_pixmap(pixmap(0x00, 0xff, 0xff, 16))
            bar.visible = true
            return nil
        end
        if hide_foreign() then
            tray:_sync_items()
            return nil
        end
        local line = capture.dump_line(s, capture.gradient_record(0, 0, 12))
        local shot = cap:shot()
        local lr, _, lb = cap:pixel(shot, 15, 20)
        local rr, _, rb = cap:pixel(shot, 24, 20)
        if not (line and lr > lb and rr < rb) then
            assert(count_ < 20, "the gradient overlay background never drew: " .. awesome._clay_tree(s))
            return nil
        end
        assert(line:find(" attach PARENT ", 1, true), "the fill is not on the floating overlay: " .. line)
        bar.visible = false
        io.stderr:write("[PASS] a gradient systray_overlay_bg draws red to blue across the overlay\n")
        return true
    end,
    -- Spacing 48 makes the tray 2 + 24 + 48 + 24 + 2 = 100 wide; its top
    -- padding row holds no icon.
    function(count_)
        if count_ == 1 then
            beautiful.bg_systray = capture.gradient(0, 100)
            tray:set_spacing(48)
            bar.visible = true
            return nil
        end
        if hide_foreign() then
            tray:_sync_items()
            return nil
        end
        local shot = cap:shot()
        local line = capture.dump_line(s, capture.gradient_record(0, 0, 100))
        if not (line and cap:near(shot, 2, 1, "#ff0000") and cap:near(shot, 97, 1, "#0000ff")) then
            assert(count_ < 20, "the gradient tray never drew: " .. awesome._clay_tree(s))
            return nil
        end
        assert(line:find("wibox.widget.systray shape", 1, true) and line:find(" box 0,0 100x", 1, true),
            "the gradient is not on the 100 wide tray: " .. line)
        bar.visible = false
        io.stderr:write("[PASS] a gradient bg_systray draws red to blue across the tray\n")
        return true
    end,

}

runner.run_steps(steps)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
