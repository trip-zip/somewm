-- Client pointer coordinates start inside the border, including titlebars.
-- A virtual pointer exercises input dispatch; root.fake_input bypasses it.

local runner = require("_runner")
local async = require("_async")
local awful = require("awful")
local utils = require("_utils")
local CLIENT = utils.binary_or_skip("./build-test/test-transient-client")

local VPOINTER = utils.binary_or_skip("./build-test/test-virtual-pointer-client")
if not CLIENT or not VPOINTER then return end

local BW, SIZE = 20, 24
local W, H = 500, 400

runner.run_async(function()
    local sg = screen[1].geometry
    awful.spawn { CLIENT, "client_btn" }
    local c = async.wait_for_client("client_btn", 5)
    assert(c, "client did not appear")

    c.floating = true
    c.border_width = BW
    for _, pos in ipairs({ "top", "left", "right", "bottom" }) do
        awful.titlebar.hide(c, pos)
    end
    c:geometry { x = sg.x + 200, y = sg.y + 200, width = W, height = H }

    assert(async.wait_for_condition(function()
        local g = c:geometry()
        return g.x == sg.x + 200 and g.y == sg.y + 200
           and g.width == W and g.height == H
    end, 5), "client geometry never settled")

    local gx, gy, mx, my
    c:connect_signal("button::press", function(_, x, y) gx, gy = x, y end)
    c:connect_signal("mouse::move", function(_, x, y) mx, my = x, y end)

    local function click(x, y)
        gx, gy, mx, my = nil, nil, nil, nil
        local g = c:geometry()
        awful.spawn(string.format("%s click %d %d %d %d left",
            VPOINTER, g.x + BW + x, g.y + BW + y, sg.width, sg.height))
        assert(async.wait_for_condition(function() return gx ~= nil end, 2),
            "client received no button::press")
        io.stderr:write(string.format("client button got %d,%d, expected %d,%d\n",
            gx, gy, x, y))
        assert(math.abs(gx - x) <= 1 and math.abs(gy - y) <= 1,
            string.format("client got x=%d y=%d, expected %d,%d", gx, gy, x, y))
        assert(async.wait_for_condition(function() return mx ~= nil end, 2),
            "client received no mouse::move")
        assert(math.abs(mx - x) <= 1 and math.abs(my - y) <= 1,
            string.format("client mouse got x=%d y=%d, expected %d,%d", mx, my, x, y))
    end

    click(5, 5)

    local bar = awful.titlebar(c, { position = "top", size = SIZE }).drawable
    local presses, bx, by = 0
    bar:connect_signal("button::press", function() presses = presses + 1 end)
    bar:connect_signal("mouse::move", function(_, x, y) bx, by = x, y end)

    -- Drawable geometry can lag titlebar creation until the next frame.
    assert(async.wait_for_condition(function()
        local g, b = c:geometry(), bar:geometry()
        return g.width == W and g.height == H + SIZE
           and b.x == g.x + BW and b.y == g.y + BW
           and b.width == W and b.height == SIZE
    end, 5), "titlebar geometry never settled")

    click(5, SIZE + 5)
    assert(presses == 0, "titlebar received a press below its area")

    click(5, 5)
    assert(async.wait_for_condition(function() return bx ~= nil end, 2),
        "titlebar received no mouse::move")
    assert(math.abs(bx - 5) <= 1 and math.abs(by - 5) <= 1,
        string.format("titlebar mouse got x=%d y=%d, expected 5,5", bx, by))

    io.stderr:write("[ALL TESTS] PASS\n")
    if c.valid then c:kill() end
    async.wait_for_no_clients(5)
    runner.done()
end)
