---------------------------------------------------------------------------
--- Regression test: button events on a titlebar carry titlebar-relative
--- coordinates.
---
--- buttonpress() passed client-relative coordinates straight to the titlebar
--- drawable. Only the top bar sits at the client origin, so the left bar was
--- off by the top bar's size and the right and bottom bars got coordinates
--- outside themselves: no widget in them ever saw a click.
---
--- The click is injected with test-virtual-pointer-client so it traverses the
--- real buttonpress() path (root.fake_input bypasses it).
---------------------------------------------------------------------------

local runner = require("_runner")
local async  = require("_async")
local awful  = require("awful")
local utils  = require("_utils")
local test_client = require("_client")

local VPOINTER = utils.binary_or_skip("./build-test/test-virtual-pointer-client")
if not VPOINTER then return end

if not test_client.is_available() then
    io.stderr:write("SKIP: no terminal available\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local SIZE = 24
local W, H = 500, 400
local POSITIONS = { "top", "left", "right", "bottom" }

runner.run_async(function()
    local sg = screen[1].geometry

    test_client("titlebar_btn")
    local c = async.wait_for_client("titlebar_btn", 5)
    assert(c, "client did not appear")

    c.floating = true
    c:geometry { x = sg.x + 200, y = sg.y + 200, width = W, height = H }

    -- Every bar must exist before any geometry is read: the left, right and
    -- bottom areas are derived from the other bars' sizes.
    local bars = {}
    for _, pos in ipairs(POSITIONS) do
        bars[pos] = awful.titlebar(c, { position = pos, size = SIZE }).drawable
    end

    -- A bar reports a stale geometry for a frame or two after it is created,
    -- and a stale one aims the click off the bar. Wait until they tile the
    -- client instead of guessing at a sleep.
    assert(async.wait_for_condition(function()
        local cg = c:geometry()
        return cg.width == W + 2 * SIZE and cg.height == H + 2 * SIZE
           and bars.top:geometry().width == cg.width
           and bars.left:geometry().height == H
    end, 5), "titlebar geometry never settled")

    for _, pos in ipairs(POSITIONS) do
        local gx, gy
        bars[pos]:connect_signal("button::press", function(_, x, y) gx, gy = x, y end)

        local g = bars[pos]:geometry()
        local cx = g.x + math.floor(g.width / 2)
        local cy = g.y + math.floor(g.height / 2)
        awful.spawn(string.format("%s click %d %d %d %d left",
                                  VPOINTER, cx, cy, sg.width, sg.height))

        assert(async.wait_for_condition(function() return gx ~= nil end, 2),
            pos .. " titlebar received no button::press")

        local ex, ey = cx - g.x, cy - g.y
        assert(math.abs(gx - ex) <= 1 and math.abs(gy - ey) <= 1,
            string.format("%s titlebar got x=%d y=%d, expected %d,%d (bar %dx%d at %d,%d)",
                pos, gx, gy, ex, ey, g.width, g.height, g.x, g.y))
    end

    io.stderr:write("[ALL TESTS] PASS\n")

    if c.valid then c:kill() end
    for _, pid in ipairs(test_client.get_spawned_pids()) do
        os.execute("kill -9 " .. pid .. " 2>/dev/null")
    end
    async.wait_for_no_clients(5)

    runner.done()
end)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
