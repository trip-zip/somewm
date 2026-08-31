-- Test: margin and background containers convert to Clay declarations, and a
-- wibar drawn that way is pixel-identical to the same wibar painted whole.
--
-- Two things are checked. First, that the boxes Clay solves for the converted
-- chain are the boxes wibox's own :fit/:layout protocol places, read back
-- through awesome._test_widget_boxes(). Second, that the screen looks the
-- same either way: setting a bgimage puts the drawable back on the path where
-- cairo paints every pixel (lua/wibox/clay.lua refuses a background image),
-- so the same tree renders twice, once converted and once whole, and the two
-- captures have to agree.
--
-- Run: make test-one TEST=tests/test-clay-widget-containers.lua

local ffi = require("ffi")
local runner = require("_runner")
local wibox = require("wibox")
local base = require("wibox.widget.base")
local cairo = require("lgi").cairo
local gshape = require("gears.shape")
local matrix = require("gears.matrix")

ffi.cdef [[
    void cairo_surface_flush(void *surface);
    unsigned char *cairo_image_surface_get_data(void *surface);
    int cairo_image_surface_get_stride(void *surface);
]]

local s = screen[1]
local BX, BY, BW, BH = 0, 0, 200, 40
local OUTER, INNER, BORDER = 4, 6, 2
local BAR_BG, BOX_BG, BORDER_COLOR = "#101010", "#204080", "#ff8000"

local bar, captured

-- A widget the compile step can never convert, so the chain always ends here.
local function leaf_widget()
    local w = base.make_widget()

    rawset(w, "fit", function(_, _, width, height) return width, height end)
    rawset(w, "draw", function(_, _, cr, width, height)
        cr:set_source_rgb(1, 0, 0)
        cr:rectangle(0, 0, width, height)
        cr:fill()
    end)
    return w
end

-- Every widget box in the drawable's hierarchy, outermost first, in drawable
-- coordinates. This is what the old layout engine places, and what Clay has
-- to agree with.
local function hierarchy_boxes()
    local boxes, h = {}, bar._drawable._widget_hierarchy

    while h do
        local x, y, w, hh = matrix.transform_rectangle(
            h:get_matrix_to_device(), 0, 0, h:get_size())

        boxes[#boxes + 1] = { x = x, y = y, width = w, height = hh }
        h = h:get_children()[1]
    end
    return boxes
end

local function box_string(b)
    return string.format("%dx%d+%d+%d", b.width, b.height, b.x, b.y)
end

local function assert_box(got, want, what)
    assert(got and got.x == want.x and got.y == want.y
        and got.width == want.width and got.height == want.height,
        string.format("%s: got %s, want %s", what,
            got and box_string(got) or "nothing", box_string(want)))
end

-- The wibar's pixels out of a screen capture, as one string.
local function capture()
    local surface = s.content

    assert(surface, "screen.content returned nothing")

    -- screen.content comes back as an lgi record; the FFI wants the pointer.
    local raw = surface._native or surface

    ffi.C.cairo_surface_flush(raw)

    local data = ffi.C.cairo_image_surface_get_data(raw)
    local stride = ffi.C.cairo_image_surface_get_stride(raw)
    local rows = {}

    for y = BY, BY + BH - 1 do
        rows[#rows + 1] = ffi.string(data + y * stride + BX * 4, BW * 4)
    end
    return table.concat(rows)
end

-- R, G, B of one pixel of a capture, drawable-local.
local function pixel(shot, x, y)
    local off = (y * BW + x) * 4

    return shot:byte(off + 3), shot:byte(off + 2), shot:byte(off + 1)
end

local function assert_pixel(shot, x, y, hex, what)
    local r, g, b = pixel(shot, x, y)
    local want_r = tonumber(hex:sub(2, 3), 16)
    local want_g = tonumber(hex:sub(4, 5), 16)
    local want_b = tonumber(hex:sub(6, 7), 16)

    assert(math.abs(r - want_r) <= 1 and math.abs(g - want_g) <= 1
        and math.abs(b - want_b) <= 1,
        string.format("%s at %d,%d: got #%02x%02x%02x, want %s",
            what, x, y, r, g, b, hex))
end

-- The wibar looks the same painted whole as it does converted. Retried
-- because the repaint the fallback needs lands a frame or two later.
local function compare(count, what)
    local shot = capture()

    if shot == captured then
        io.stderr:write("[PASS] " .. what .. " draws what the chain drew\n")
        return true
    end
    if count < 20 then
        return
    end
    for y = 0, BH - 1 do
        for x = 0, BW - 1 do
            local r, g, b = pixel(shot, x, y)
            local wr, wg, wb = pixel(captured, x, y)

            assert(r == wr and g == wg and b == wb, string.format(
                "%s differs at %d,%d: #%02x%02x%02x, converted #%02x%02x%02x",
                what, x, y, r, g, b, wr, wg, wb))
        end
    end
    error(what .. " differs outside the compared channels")
end

local steps = {
    function(count)
        if count == 1 then
            bar = wibox {
                x = BX, y = BY, width = BW, height = BH,
                visible = true, screen = s, bg = BAR_BG,
            }
            bar:setup {
                widget = wibox.container.margin,
                margins = OUTER,
                {
                    widget = wibox.container.background,
                    bg = BOX_BG,
                    border_width = BORDER,
                    border_color = BORDER_COLOR,
                    {
                        widget = wibox.container.margin,
                        margins = INNER,
                        leaf_widget(),
                    },
                },
            }
        end
        if #awesome._test_widget_boxes(bar.drawin) > 0 then
            return true
        end
        assert(count < 20, "the widget tree never converted")
    end,

    -- Clay's boxes for the chain, against wibox's own.
    function()
        local boxes = awesome._test_widget_boxes(bar.drawin)

        assert(#boxes == 5, "expected five nodes, got " .. #boxes)
        assert_box(boxes[1], { x = 0, y = 0, width = BW, height = BH },
            "the drawable's own background")
        assert_box(boxes[2], { x = 0, y = 0, width = BW, height = BH },
            "the outer margin")
        assert_box(boxes[3], { x = OUTER, y = OUTER,
            width = BW - 2 * OUTER, height = BH - 2 * OUTER }, "the background")
        assert_box(boxes[4], { x = OUTER, y = OUTER,
            width = BW - 2 * OUTER, height = BH - 2 * OUTER },
            "the inner margin")
        assert_box(boxes[5], { x = OUTER + INNER, y = OUTER + INNER,
            width = BW - 2 * (OUTER + INNER),
            height = BH - 2 * (OUTER + INNER) }, "the raster leaf")

        -- The chain's widget nodes are boxes 2 to 5; the hierarchy holds the
        -- same widgets, starting at the outer margin.
        local want = hierarchy_boxes()

        for i = 1, #want do
            assert_box(boxes[i + 1], want[i],
                "Clay and wibox disagree at hierarchy depth " .. i)
        end
        io.stderr:write("[PASS] Clay solves the boxes wibox places\n")
        return true
    end,

    -- What the converted chain draws.
    function()
        local shot = capture()

        assert_pixel(shot, 1, 1, BAR_BG, "the drawable's own background")
        assert_pixel(shot, OUTER + 1, OUTER + 1, BORDER_COLOR,
            "the background's border")
        assert_pixel(shot, OUTER + BORDER + 2, OUTER + BORDER + 2, BOX_BG,
            "the background's fill")
        assert_pixel(shot, math.floor(BW / 2), math.floor(BH / 2), "#ff0000",
            "the raster leaf")
        captured = shot
        io.stderr:write("[PASS] the converted chain draws where it should\n")
        return true
    end,

    -- The same tree painted whole. A shape puts the drawable back on the
    -- path where cairo paints every pixel, because the mask applies to those
    -- pixels; a full-rectangle shape masks nothing away.
    function(count)
        if count == 1 then
            bar.shape = gshape.rectangle
        end
        if #awesome._test_widget_boxes(bar.drawin) == 0 then
            return true
        end
        assert(count < 20, "a shape did not put the drawable back on cairo")
    end,

    function(count)
        return compare(count, "a shaped drawable")
    end,

    -- And a background image, the other thing the chain cannot carry.
    function(count)
        if count == 1 then
            bar.shape = nil
        end
        if #awesome._test_widget_boxes(bar.drawin) > 0 then
            return true
        end
        assert(count < 20, "dropping the shape did not convert the tree again")
    end,

    function(count)
        if count == 1 then
            bar.bgimage = cairo.ImageSurface(cairo.Format.ARGB32, 1, 1)
        end
        if #awesome._test_widget_boxes(bar.drawin) == 0 then
            return true
        end
        assert(count < 20, "a background image did not put the drawable back")
    end,

    function(count)
        return compare(count, "a background image")
    end,

    function()
        bar.visible = false
        return true
    end,
}

runner.run_steps(steps)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
