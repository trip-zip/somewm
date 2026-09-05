-- Pixel readback for the converted-widget tests: a box of a screen's content
-- as one string, single pixels out of it, and the comparison of two captures.
--
-- Two ways to draw one wibox have to land the same pixels: the converted tree
-- (Clay rectangles plus raster leaves) and the whole surface painted by cairo.
-- The drawable goes back to painting whole when it gains a shape or a
-- background image, so a test converts, captures, sets one of those, and
-- compares.

local ffi = require("ffi")

ffi.cdef [[
    void cairo_surface_flush(void *surface);
    unsigned char *cairo_image_surface_get_data(void *surface);
    int cairo_image_surface_get_stride(void *surface);
]]

local base = require("wibox.widget.base")
local gcolor = require("gears.color")
local utils = require("_utils")

local capture = {}

-- A widget the compile step can never convert, with a preferred size: as
-- wide as asked (or as offered, for math.huge), as tall as offered unless
-- given, so a fixed layout sizes it and an align or a place has something
-- to center. Draws one flat color.
function capture.leaf_widget(width, height, color)
    local w = base.make_widget()

    rawset(w, "fit", function(_, _, avail_w, avail_h)
        return math.min(width, avail_w), math.min(height or avail_h, avail_h)
    end)
    rawset(w, "draw", function(_, _, cr, w2, h2)
        cr:set_source(gcolor(color))
        cr:rectangle(0, 0, w2, h2)
        cr:fill()
    end)
    return w
end

function capture.assert_box(got, want, what)
    assert(got, what .. ": no box")

    local ok, err = pcall(utils.assert_geometry, got, want)

    assert(ok, what .. ": " .. tostring(err))
end

-- A step that runs `setup` once and then waits for the readback to say the
-- tree did or did not convert. The fallbacks repaint a frame or two later,
-- so every one of these polls.
function capture.step_until(get_bar, converted, setup, what)
    return function(count)
        if count == 1 then
            setup()
        end
        if (#awesome._test_widget_boxes(get_bar().drawin) > 0) == converted then
            return true
        end
        assert(count < 20, what)
    end
end

-- A capture of the box (x, y, width, height) of screen s.
function capture.new(s, x, y, width, height)
    local self = { screen = s, x = x, y = y, width = width, height = height }

    return setmetatable(self, { __index = capture })
end

-- The box's pixels out of a screen capture, as one string.
function capture:shot()
    local surface = self.screen.content

    assert(surface, "screen.content returned nothing")

    -- screen.content comes back as an lgi record; the FFI wants the pointer.
    local raw = surface._native or surface

    ffi.C.cairo_surface_flush(raw)

    local data = ffi.C.cairo_image_surface_get_data(raw)
    local stride = ffi.C.cairo_image_surface_get_stride(raw)
    local rows = {}

    for row = self.y, self.y + self.height - 1 do
        rows[#rows + 1] = ffi.string(data + row * stride + self.x * 4, self.width * 4)
    end
    return table.concat(rows)
end

-- R, G, B of one pixel of a shot, box-local.
function capture:pixel(shot, x, y)
    local off = (y * self.width + x) * 4

    return shot:byte(off + 3), shot:byte(off + 2), shot:byte(off + 1)
end

function capture:assert_pixel(shot, x, y, hex, what)
    local r, g, b = self:pixel(shot, x, y)
    local want_r = tonumber(hex:sub(2, 3), 16)
    local want_g = tonumber(hex:sub(4, 5), 16)
    local want_b = tonumber(hex:sub(6, 7), 16)

    assert(math.abs(r - want_r) <= 1 and math.abs(g - want_g) <= 1
        and math.abs(b - want_b) <= 1,
        string.format("%s at %d,%d: got #%02x%02x%02x, want %s",
            what, x, y, r, g, b, hex))
end

-- A step body: the box looks the same now as in `captured`. Retried because
-- the repaint the fallback needs lands a frame or two later; after twenty
-- tries the first differing pixel is the failure.
function capture:compare(count, captured, what)
    local shot = self:shot()

    if shot == captured then
        io.stderr:write("[PASS] " .. what .. " draws what the tree drew\n")
        return true
    end
    if count < 20 then
        return
    end
    for y = 0, self.height - 1 do
        for x = 0, self.width - 1 do
            local r, g, b = self:pixel(shot, x, y)
            local wr, wg, wb = self:pixel(captured, x, y)

            assert(r == wr and g == wg and b == wb, string.format(
                "%s differs at %d,%d: #%02x%02x%02x, converted #%02x%02x%02x",
                what, x, y, r, g, b, wr, wg, wb))
        end
    end
    error(what .. " differs outside the compared channels")
end

return capture

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
