-- Pixel readback, color leaves and capture comparisons for widget-tree tests.

local base = require("wibox.widget.base")
local utils = require("_utils")

local capture = {}

-- A flat color leaf with a preferred size, growing where no size is given.
function capture.leaf_widget(width, height, color)
    local w = base.make_widget()

    w._clay = { describe = function()
        return { bg = require("wibox.clay").solid_rgba(color),
            w = width == math.huge and "grow" or width, h = height or "grow" }
    end, name = "leaf" }
    return w
end

function capture.assert_box(got, want, what)
    assert(got, what .. ": no box")

    local ok, err = pcall(utils.assert_geometry, got, want)

    assert(ok, what .. ": " .. tostring(err))
end

-- R, G, B, A of one pixel of a content surface (screen.content,
-- root.content), at surface coordinates.
function capture.read(surface, x, y)
    assert(surface, "no content surface")

    -- An lgi record carries the pointer in _native; a bare one is the pointer.
    local ok, native = pcall(function() return surface._native end)
    local raw = ok and native or surface
    local b, g, r, a = awesome._surface_pixels(raw, x, y, 1, 1):byte(1, 4)

    return r, g, b, a
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

    -- screen.content comes back as an lgi record; the binding wants the pointer.
    local raw = surface._native or surface

    return awesome._surface_pixels(raw, self.x, self.y, self.width, self.height)
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

-- Compare the box with `captured`, allowing twenty frames for redraw.
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
