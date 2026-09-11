---------------------------------------------------------------------------
-- Test: an imagebox converts to a Clay image element
--
-- A converted imagebox holds one image leaf whose pixels are the widget's
-- own surface, with the image's aspect ratio: the renderer scales the
-- surface into the box Clay solved (third_party/clay.h:414-416). A clip
-- shape is ignored.
--
-- Run: make test-one TEST=tests/test-clay-imagebox.lua
---------------------------------------------------------------------------

local runner = require("_runner")
local capture = require("_widget_capture")
local wibox = require("wibox")
local gcolor = require("gears.color")
local gshape = require("gears.shape")
local cairo = require("lgi").cairo

local s = screen[1]
local BX, BY, BW, BH = 0, 0, 400, 24
local cap = capture.new(s, BX, BY, BW, BH)
local bar

local function solid(color)
    local img = cairo.ImageSurface(cairo.Format.ARGB32, 16, 16)
    local cr = cairo.Context(img)

    cr:set_source(gcolor(color))
    cr:paint()
    return img
end

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

local function imageboxes(list)
    local out = {}
    for i, node in ipairs(list) do
        if node.class == "wibox.widget.imagebox" then
            local child = list[i + 1]
            out[#out + 1] = { node = node,
                image = child and child.depth == node.depth + 1
                    and child.line:find(" image 16x16 ", 1, true) and child or nil }
        end
    end
    return out
end

local steps = {
    function(count)
        if count == 1 then
            bar = wibox {
                x = BX, y = BY, width = BW, height = BH, screen = s,
                bg = "#101010", visible = true,
            }
            bar:setup {
                layout = wibox.layout.fixed.horizontal,
                spacing = 10,
                wibox.widget.imagebox(solid("#ff0000")),
                { wibox.widget.imagebox(solid("#00ff00")), margins = 4,
                    widget = wibox.container.margin },
                wibox.widget.imagebox(solid("#0000ff"), true, gshape.circle),
                wibox.widget.imagebox(),
            }
            return nil
        end

        local head, list = nodes()

        if not head or (head:find("converted", 1, true) and #list == 0) then
            assert(count < 20, "the bar never reached the dump")
            return nil
        end
        assert(head:find("converted", 1, true), "the bar did not convert: " .. head)

        local ib = imageboxes(list)

        assert(#ib == 4, "expected four imageboxes, got " .. #ib)
        assert(not ib[1].node.image and ib[1].image,
            "the first imagebox is not an image element: " .. ib[1].node.line)
        assert(not ib[2].node.image and ib[2].image,
            "the padded imagebox is not an image element: " .. ib[2].node.line)
        assert(#awesome._test_widget_boxes(bar.drawin) == 7, "the converted widgets do not all have boxes")
        assert(ib[3].image, "the unclipped imagebox is not an image element")
        assert(not ib[4].node.image and not ib[4].image
            and ib[4].node.box.width == 0,
            "an imagebox with no image is not an empty element: " .. ib[4].node.line)

        -- Scaled to the bar's height, and to the padded slot's, keeping the
        -- square; the margin's slot was sized for the taller image.
        local first, padded = ib[1].image.box, ib[2].image.box

        assert(first.width == 24 and first.height == 24,
            "the first image is not 24x24: " .. ib[1].image.line)
        assert(padded.width == 16 and padded.height == 16 and padded.y == 4,
            "the padded image is not 16x16 at y 4: " .. ib[2].image.line)
        io.stderr:write("[PASS] imageboxes convert to image elements\n")
        return true
    end,

    -- The renderer draws the surfaces where Clay put them.
    function(count)
        local _, list = nodes()
        local ib = imageboxes(list)
        local shot = cap:shot()
        local first, padded = ib[1].image.box, ib[2].image.box
        local ok = pcall(function()
            cap:assert_pixel(shot, first.x + 12, 12, "#ff0000", "the first image")
            cap:assert_pixel(shot, padded.x + 8, 12, "#00ff00", "the padded image")
        end)

        if ok then
            io.stderr:write("[PASS] the renderer draws the images\n")
            bar.visible = false
            return true
        end
        assert(count < 20, "the images were not drawn")
    end,
}

runner.run_steps(steps)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
