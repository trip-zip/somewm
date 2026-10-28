---------------------------------------------------------------------------
-- Test: textbox:get_preferred_size answers the size Clay draws the text at
--
-- A content-sized popup holding only a textbox solves to the textbox's fit
-- size, so its geometry is the measurement to match: one line, several
-- lines, and markup in a non-default font through get_markup_geometry and
-- menubar.utils.compute_text_width.
--
-- Run: make test-one TEST=tests/test-textbox-preferred-size.lua
---------------------------------------------------------------------------

-- luacheck: globals screen awesome
local runner = require("_runner")
local async = require("_async")
local gears = require("gears")
local awful = require("awful")
local wibox = require("wibox")
local menubar_utils = require("menubar.utils")

local function solved(widget)
    local popup = awful.popup { screen = screen[1], visible = true, ontop = true,
        border_width = 0, shadow = false, placement = awful.placement.top_left,
        widget = widget }
    gears.timer.run_delayed_calls_now()
    awesome._test_redeclare()
    async.sleep(0.05)
    local geo = popup:geometry()
    popup.visible = false
    return geo.width, geo.height
end

local function near(a, b) return math.abs(a - b) < 1 end

runner.run_async(function()
    async.sleep(0.01)
    local s = screen[1]

    local one = wibox.widget.textbox("preferred size probe")
    local w1, h1 = one:get_preferred_size(s)
    assert(w1 > 0 and h1 > 0, "a one-line textbox measured " .. w1 .. "x" .. h1)
    assert(w1 == math.floor(w1) and h1 == math.floor(h1), "a measurement is not whole pixels")
    -- The measurement never rounds below the fit size, so a popup forced to
    -- it keeps the text on one line.
    local forced = wibox.widget { widget = wibox.widget.textbox, text = "preferred size probe",
        forced_width = w1, forced_height = h1 }
    local fw1, fh1 = solved(forced)
    assert(fw1 == w1 and fh1 == h1, ("forced to %dx%d drew %dx%d"):format(w1, h1, fw1, fh1))
    local pw, ph = solved(one)
    assert(near(w1, pw) and near(h1, ph),
        ("one line measured %gx%g, drawn %dx%d"):format(w1, h1, pw, ph))

    local circle = wibox.widget.textbox("  ")
    circle.font = "DejaVu Sans 10"
    local cw, ch = circle:get_preferred_size(s)
    pw, ph = solved(circle)
    assert(near(cw, pw) and near(ch, ph),
        ("padded icon measured %gx%g, drawn %dx%d"):format(cw, ch, pw, ph))

    local three = wibox.widget.textbox("first\na much longer second line\nthird")
    local w3, h3 = three:get_preferred_size(s)
    assert(near(h3, 3 * h1), ("three lines measured %g high, one line %g"):format(h3, h1))
    pw, ph = solved(three)
    assert(near(w3, pw) and near(h3, ph),
        ("three lines measured %gx%g, drawn %dx%d"):format(w3, h3, pw, ph))

    local markup, font = "<b>bold</b> and plain", "Sans 18"
    local geo = wibox.widget.textbox.get_markup_geometry(markup, s, font)
    pw, ph = solved(wibox.widget { widget = wibox.widget.textbox, markup = markup, font = font })
    assert(near(geo.width, pw) and near(geo.height, ph),
        ("markup measured %gx%g, drawn %dx%d"):format(geo.width, geo.height, pw, ph))
    assert(geo.height > h1, "an 18pt font measured no taller than the default")
    assert(menubar_utils.compute_text_width(markup, s, font) == geo.width,
        "compute_text_width disagrees with get_markup_geometry")
    assert(menubar_utils.compute_textbox_width(one, s) == w1,
        "compute_textbox_width disagrees with get_preferred_size")

    local dw, dh = one:get_preferred_size_at_dpi(s.dpi)
    assert(dw == w1 and dh == h1, "get_preferred_size_at_dpi disagrees at the screen's dpi")

    local ew, eh = wibox.widget.textbox(""):get_preferred_size(s)
    assert(ew == 0 and eh == 0, "an empty textbox measured " .. ew .. "x" .. eh)

    -- Pango rounds advances to device pixels, so a fractional scale measures
    -- differently; the answer follows the output's scale.
    s.scale = 1.5
    async.sleep(0.05)
    local fw, fh = one:get_preferred_size(s)
    pw, ph = solved(one)
    local cfw, cfh = circle:get_preferred_size(s)
    local cpw, cph = solved(circle)
    assert(near(cfw, cpw) and near(cfh, cph), "fractional padded icon size differs")
    s.scale = 1
    assert(near(fw, pw) and near(fh, ph),
        ("at scale 1.5 measured %gx%g, drawn %dx%d"):format(fw, fh, pw, ph))

    -- A fake screen has no output of its own; it measures on the one it covers.
    async.sleep(0.05)
    local fake = screen.fake_add(s.geometry.x, s.geometry.y, 200, 200)
    local kw, kh = one:get_preferred_size(fake)
    fake:fake_remove()
    assert(kw == w1 and kh == h1, ("a fake screen measured %gx%g"):format(kw, kh))

    io.stderr:write(("[PASS] one line %gx%g, three lines %gx%g, markup %gx%g, scale 1.5 %gx%g\n")
        :format(w1, h1, w3, h3, geo.width, geo.height, fw, fh))
    runner.done()
end)
