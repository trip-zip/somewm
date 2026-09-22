---------------------------------------------------------------------------
-- Test: the pointer image is a leaf of the output's tree
--
-- The themed cursor is declared at the pointer less its hotspot on the output
-- under the pointer, in the top band. It takes no input and captures leave it
-- out. A client's cursor surface replaces it while the client has pointer
-- focus. The lock section sits under it. A second output at another scale
-- declares it there, and only there, while the pointer is on it.
---------------------------------------------------------------------------

local runner = require("_runner")
local awful = require("awful")
local wibox = require("wibox")
local surface = require("gears.surface")
local capture = require("_widget_capture")
local lock = require("_lock_helper")

local CLIENT = "./build-test/test-pointer-logger"
local APP_ID = "cursor_client"

-- The cursor record of a screen's tree: name, size, source and the
-- output-local offset the leaf was declared at.
local function cursor_record(s)
    local dump = awesome._clay_tree(s)
    for line in dump:gmatch("[^\n]+") do
        local name, w, h, src, ox, oy = line:match("^  cursor (%S+) w=fixed%((%d+)%) "
            .. "h=fixed%((%d+)%) (%a+) attach ROOT offset (%-?%d+),(%-?%d+) band 32767")
        if name then
            return { name = name, w = tonumber(w), h = tonumber(h), src = src,
                x = tonumber(ox), y = tonumber(oy) }, dump
        end
    end
    return nil, dump
end

-- Whether the leaf holds the layout point (the hotspot is inside the image).
local function covers(rec, s, x, y)
    x, y = x - s.geometry.x, y - s.geometry.y
    return rec and x >= rec.x and x < rec.x + rec.w and y >= rec.y and y < rec.y + rec.h
end

local function until_cursor(s, x, y, src, count)
    local rec, dump = cursor_record(s)
    if covers(rec, s, x, y) and rec.src == src then
        return rec
    end
    assert(count < 30, string.format("no %s cursor leaf holding %d,%d on screen %d\n%s",
        src, x, y, s.index, dump))
end

-- Drive a real motion through motionnotify at x, y: warp, then nudge back
-- and forth, so pointer focus follows (mouse.coords alone runs no hit test).
local function move_to(x, y)
    mouse.coords({ x = x, y = y })
    mouse._fake_motion(1, 0)
    mouse._fake_motion(-1, 0)
end

local s = screen[1]
local wb, client_pid, c, s2

runner.run_steps({
    -- The compositor parks the pointer at 100,100; the themed leaf is there.
    function(count)
        local p = mouse.coords()
        local rec = until_cursor(s, p.x, p.y, "theme", count)
        if not rec then return end
        assert(rec.w > 0 and rec.h > 0)
        return true
    end,

    -- A warp moves the leaf.
    function()
        mouse.coords({ x = 400, y = 300 })
        return true
    end,
    function(count)
        return until_cursor(s, 400, 300, "theme", count) and true
    end,

    -- The leaf takes no input: a wibox under the pointer is what is under
    -- the pointer, and a capture shows the wibox, not the cursor.
    function()
        wb = wibox({ x = 380, y = 280, width = 100, height = 100, visible = true,
            ontop = true, bg = "#ff0000" })
        return true
    end,
    function(count)
        if mouse.current_wibox ~= wb then
            assert(count < 30, "the wibox under the pointer is not what is under the pointer")
            return
        end
        local shot = surface(root.content())
        for _, d in ipairs({ { 0, 0 }, { 6, 6 }, { 12, 12 }, { 12, 0 }, { 0, 12 } }) do
            local r, g, b = capture.read(shot, 400 + d[1], 300 + d[2])
            assert(r == 255 and g == 0 and b == 0, string.format(
                "root.content pixel %d,%d is %d,%d,%d, expected the wibox's red",
                400 + d[1], 300 + d[2], r, g, b))
        end
        wb.visible = false
        return true
    end,

    -- A client with pointer focus sets a 16x16 cursor surface, hotspot 3,5.
    function()
        client_pid = awful.spawn(string.format("%s --app-id %s --size 300x200 --cursor 16x16+3+5",
            CLIENT, APP_ID))
        assert(type(client_pid) == "number", "spawn returned: " .. tostring(client_pid))
        return true
    end,
    function(count)
        for _, cl in ipairs(client.get()) do
            if cl.class == APP_ID then c = cl end
        end
        if not c then
            assert(count < 50, "the cursor client never appeared")
            return
        end
        c.floating = true
        c.border_width = 0
        c:geometry({ x = 600, y = 200, width = 300, height = 200 })
        return true
    end,
    function()
        move_to(700, 300)
        return true
    end,
    function(count)
        local rec = until_cursor(s, 700, 300, "protocol", count)
        if not rec then return end
        assert(rec.w == 16 and rec.h == 16 and rec.x == 700 - 3 and rec.y == 300 - 5,
            string.format("client cursor leaf %dx%d+%d+%d, expected 16x16+697+295",
                rec.w, rec.h, rec.x, rec.y))
        return true
    end,

    -- Back over the root, the theme's cursor returns.
    function()
        move_to(100, 100)
        return true
    end,
    function(count)
        if not until_cursor(s, 100, 100, "theme", count) then return end
        c:kill()
        return true
    end,

    -- The lock section sits under the pointer image.
    function()
        lock.setup()
        awesome.lock()
        assert(awesome.locked, "should be locked")
        return true
    end,
    function(count)
        local rec, dump = cursor_record(s)
        if not (rec and dump:find("\n  LOCK ", 1, true)) then
            assert(count < 30, "no lock section under the cursor leaf\n" .. dump)
            return
        end
        awesome.authenticate(lock.TEST_PASSWORD)
        awesome.unlock()
        assert(not awesome.locked, "should be unlocked")
        lock.teardown()
        return true
    end,

    -- A second output at another scale: the pointer over it puts the leaf
    -- in its tree, at its scale, and nowhere else.
    function()
        if not awesome._test_add_output then
            io.stderr:write("second output skipped: awesome._test_add_output not available\n")
            return true
        end
        assert(awesome._test_add_output(800, 600), "_test_add_output failed")
        return true
    end,
    function(count)
        if not awesome._test_add_output then return true end
        if screen.count() < 2 then
            assert(count < 30, "the second screen never appeared")
            return
        end
        s2 = screen[screen.count()]
        s2.scale = 1.5
        return true
    end,
    function(count)
        if not s2 then return true end
        local g = s2.geometry
        if g.width == 800 then
            assert(count < 30, "the second screen never took its scale")
            return
        end
        mouse.coords({ x = g.x + math.floor(g.width / 2), y = g.y + math.floor(g.height / 2) })
        return true
    end,
    function(count)
        if not s2 then return true end
        local g = s2.geometry
        local rec = until_cursor(s2, g.x + math.floor(g.width / 2),
            g.y + math.floor(g.height / 2), "theme", count)
        if not rec then return end
        local other = cursor_record(s)
        assert(not other, "screen 1 still declares the pointer image")
        return true
    end,
}, { wait_per_step = 5 })

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
