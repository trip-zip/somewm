---------------------------------------------------------------------------
-- Test: Clay's debug inspector on a screen
--
-- screen.inspector puts Clay's own panel in the screen's tree: the dump
-- header says so, and the panel's header row is a RECTANGLE at the top
-- right, as wide as the theme says. A restyle re-solves every open panel,
-- disabling removes it, the panel's own x button closes it through the seat
-- mirror, and property::inspector fires for every change. While the panel
-- is up the workarea gives up its width, like beside a right wibar.
--
-- Run: make test-one TEST=tests/test-clay-inspector.lua
---------------------------------------------------------------------------

local runner = require("_runner")
local beautiful = require("beautiful")
local inspector = require("somewm.inspector")

local s = screen[1]
local geo = s.geometry
local workarea = s.workarea.width
local signals = {}

s:connect_signal("property::inspector", function(scr)
    signals[#signals + 1] = scr.inspector
end)

local function dump()
    return awesome._clay_tree(s)
end

-- The dump header's inspector word for the desktop band.
local function state()
    return dump():match("band desktop scale [%d.]+ inspector (%a+)")
end

-- The panel's header row: a RECTANGLE in the panel's band, at the top
-- right, `width` wide and one 30-unit row tall.
local function header(width)
    local box = string.format("box %d,0 %dx30", geo.width - width, width)

    for line in dump():gmatch("[^\n]+") do
        if line:find("RECTANGLE", 1, true) and line:find("z=32765", 1, true)
                and line:find(box, 1, true) then
            return line
        end
    end
    return nil
end

-- The workarea is `strut` narrower than before the panel.
local function assert_workarea(strut)
    assert(s.workarea.width == workarea - strut, "the workarea is "
        .. s.workarea.width .. " wide with a " .. strut .. " panel")
end

local function assert_agrees()
    for line in dump():gmatch("[^\n]+") do
        assert(not line:find("[tree!=scene]", 1, true),
            "the scene disagrees with the tree: " .. line)
    end
end

local steps = {
    function()
        assert(state() == "off", "the inspector starts " .. tostring(state()))
        assert(s.inspector == false, "screen.inspector reads true before any set")
        s.inspector = true
        assert(s.inspector == true, "screen.inspector reads false after the set")
        return true
    end,

    function(count)
        if state() ~= "on" or not header(400) then
            assert(count < 20, "the panel never reached the dump:\n" .. dump())
            return nil
        end
        assert_agrees()
        assert_workarea(400)
        io.stderr:write("[PASS] the panel is in the dump at the top right\n")
        return true
    end,

    -- A restyle re-solves: the open panel takes the new width.
    function(count)
        if count == 1 then
            beautiful.inspector_width = 300
            inspector.restyle()
            return nil
        end
        if not header(300) then
            assert(count < 20, "the panel never took the new width:\n" .. dump())
            return nil
        end
        assert(not header(400), "the old width is still drawn")
        assert_agrees()
        assert_workarea(300)
        io.stderr:write("[PASS] a restyle re-solves the panel\n")
        return true
    end,

    function(count)
        if count == 1 then
            s.inspector = false
        end
        if state() ~= "off" or header(300) then
            assert(count < 20, "the panel never left the dump:\n" .. dump())
            return nil
        end
        assert(#signals == 2 and signals[1] == true and signals[2] == false,
            "property::inspector fired " .. #signals .. " times")
        assert_workarea(0)
        io.stderr:write("[PASS] disabling removes the panel\n")
        return true
    end,

    function(count)
        if count == 1 then
            assert(inspector.toggle(s) == true, "toggle did not enable")
            return nil
        end
        if not header(300) then
            assert(count < 20, "the panel never came back:\n" .. dump())
            return nil
        end
        return true
    end,

    -- The x button at the right end of the header row closes the panel
    -- from inside the solve, through the seat mirror, and the screen hears
    -- the same signal the setter emits.
    function(count)
        if count == 1 then
            local x, y = geo.x + geo.width - 20, geo.y + 15

            root.fake_input("motion_notify", false, x, y)
            root.fake_input("motion_notify", false, x, y)
            root.fake_input("button_press", 1)
            root.fake_input("button_release", 1)
            return nil
        end
        if state() ~= "off" or header(300) then
            assert(count < 20, "the x button never closed the panel:\n" .. dump())
            return nil
        end
        assert(#signals == 4 and signals[3] == true and signals[4] == false,
            "property::inspector fired " .. #signals .. " times")
        assert(s.inspector == false, "screen.inspector still reads true")
        assert_workarea(0)
        io.stderr:write("[PASS] the x button closes the panel\n")
        return true
    end,
}

runner.run_steps(steps)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
