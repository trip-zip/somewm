---------------------------------------------------------------------------
-- Test: a lock surface follows its screen's geometry
--
-- The bundled lockscreen builds one full-screen wibox per screen in
-- lockscreen.init(). Changing an existing screen's geometry afterwards adds
-- and removes no screen, so only the module's property::geometry handler can
-- keep the surface over its screen.
---------------------------------------------------------------------------

local runner = require("_runner")
local lock = require("_lock_helper")
local lockscreen = require("lockscreen")

local s = screen[1]
local before

-- awesome.lock_surface is nil while the surface is hidden, because a drawin
-- is in the object registry only while visible, and two of the checks below
-- run before the lock. Read the module's own table instead.
local function surface_of(scr)
    for i = 1, 60 do
        local name, value = debug.getupvalue(lockscreen.init, i)
        if not name then break end
        if name == "surfaces" then return value[scr] end
    end
end

local function assert_covers(scr, when)
    local wb = assert(surface_of(scr), "no lock surface for screen " .. scr.index)
    local g, sg = wb:geometry(), scr.geometry
    assert(g.x == sg.x and g.y == sg.y
        and g.width == sg.width and g.height == sg.height,
        string.format("%s: surface %dx%d+%d+%d, screen %dx%d+%d+%d",
            when, g.width, g.height, g.x, g.y,
            sg.width, sg.height, sg.x, sg.y))
    return wb
end

runner.run_steps({
    function()
        lockscreen.init()
        before = s.geometry
        assert_covers(s, "at init")
        return true
    end,

    -- Outputs come up at scale 1 and get their configured scale afterwards.
    function()
        s.scale = 1.5
        return true
    end,

    function(count)
        local g = s.geometry
        if g.width == before.width and g.height == before.height then
            assert(count < 30, "the screen geometry never changed")
            return
        end
        assert_covers(s, "after the geometry change, before locking")
        return true
    end,

    function()
        awesome.lock()
        assert(awesome.locked, "should be locked")
        assert_covers(s, "while locked")
        return true
    end,

    function(count)
        local wb = assert_covers(s, "in the locked dump")
        local g = wb:geometry()
        local dump = awesome._clay_tree(s)
        local want = string.format("drawin screen %d %dx%d+%d+%d",
            s.index, g.width, g.height, g.x, g.y)
        if dump:find("LOCK ", 1, true) and dump:find(want, 1, true) then
            return true
        end
        assert(count < 30, "the lock section never showed " .. want
            .. "\n" .. dump)
    end,

    function()
        awesome.authenticate(lock.TEST_PASSWORD)
        awesome.unlock()
        assert(not awesome.locked, "should be unlocked")
        lock.teardown()
        return true
    end,
}, { kill_clients = false })

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
