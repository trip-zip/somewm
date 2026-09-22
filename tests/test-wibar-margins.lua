--- Test that fractional margins do not make a wibar grow.
--
-- The margins are the padding of the bar's slot in the output's flow, in
-- whole pixels, and the wibar's geometry is the box its tree solved to. The
-- placement code used to add the margins to the geometry it read and remove
-- them from the geometry it wrote, so a fractional margin made the wibar one
-- pixel taller every time the attached placement ran.

local wibar = require("awful.wibar")

local steps = {}

-- A fractional margin, as half of an odd theme size gives. It is rounded to 11.
local margin, rounded = 10.5, 11

local height = 24
local sgeo   = screen.primary.geometry

local expected = {
    x      = sgeo.x + rounded,
    y      = sgeo.y + rounded,
    width  = sgeo.width - 2 * rounded,
    height = height,
}

local w

-- The top and bottom margins are on the same axis as the height of a top
-- wibar. Only the top one is set, so their sum is fractional.
table.insert(steps, function()
    -- Without the fix, this alone overflows the C stack.
    w = wibar {
        position = "top",
        screen   = screen.primary,
        height   = height,
        margins  = { top = margin, left = margin, right = margin },
    }

    return true
end)

-- The geometry arrives with the first frame that solves the bar.
table.insert(steps, function(count)
    local geo = w:geometry()

    if geo.x == expected.x and geo.width == expected.width then
        return true
    end
    assert(count < 30, string.format("the wibar never settled at %dx%d+%d+%d",
        geo.width, geo.height, geo.x, geo.y))
end)

-- Keep checking the geometry for a while to make sure it stays put.
for _=1, 3 do
    table.insert(steps, function()
        local geo = w:geometry()

        for _, key in ipairs {"x", "y", "width", "height"} do
            assert(geo[key] == expected[key], string.format(
                "regression: fractional margins changed the %s to %d, "..
                "expected %d", key, geo[key], expected[key]
            ))
        end

        return true
    end)
end

table.insert(steps, function()
    -- The slot covers the wibar and the margin above it.
    local expected_y = expected.y + expected.height

    assert(screen.primary.workarea.y == expected_y, string.format(
        "regression: the workarea starts at %d, expected %d",
        screen.primary.workarea.y, expected_y))

    return true
end)

require("_runner").run_steps(steps)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
