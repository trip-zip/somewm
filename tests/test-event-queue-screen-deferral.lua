---------------------------------------------------------------------------
--- Test: output and screen signals from C paths defer to the frame boundary
--
-- Verifies:
--   1. Screen property::geometry triggered by a C-side layout change
--      (output position -> updatemons) is NOT delivered synchronously;
--      it arrives at the next some_refresh() drain, carrying the old
--      geometry argument through the queue.
--   2. Lua-initiated paths bypass the queue: screen.fake_add delivers
--      the class "list" signal synchronously.
--   3. property::geometry still precedes property::workarea on that C
--      path. Both go through the queue, so the synchronous workarea
--      emitter cannot overtake the geometry signal it should follow.
--   4. A removed screen reports valid == false without raising, and its
--      other properties raise "invalid object" (AwesomeWM parity).
---------------------------------------------------------------------------

local runner = require("_runner")

local geo_count = 0
local geo_at_set
local geo_old_arg

local list_count = 0

-- Delivery order of the two signals the C geometry path emits.
local order = {}

local fake_screen

local steps = {
    -- Step 1: C-initiated geometry change is not delivered synchronously
    function()
        local s = screen[1]
        s:connect_signal("property::geometry", function(_, old)
            geo_count = geo_count + 1
            geo_old_arg = old
            order[#order + 1] = "geometry"
        end)
        s:connect_signal("property::workarea", function()
            order[#order + 1] = "workarea"
        end)
        local o = output[1]
        local pos = o.position
        o.position = { x = pos.x + 100, y = pos.y }
        geo_at_set = geo_count
        return true
    end,

    -- Step 2: the signal arrives at the next drain, with the old geometry
    function()
        if geo_count == 0 then
            return nil
        end
        assert(geo_at_set == 0,
            "property::geometry was delivered synchronously (count at set: "
            .. tostring(geo_at_set) .. ")")
        assert(type(geo_old_arg) == "table" and geo_old_arg.width,
            "old geometry argument lost through the event queue")
        assert(order[1] == "geometry",
            "property::workarea overtook property::geometry (order: "
            .. table.concat(order, ", ") .. ")")
        return true
    end,

    -- Step 3: screen.fake_add (Lua path) delivers class "list" synchronously
    function()
        screen.connect_signal("list", function()
            list_count = list_count + 1
        end)
        fake_screen = screen.fake_add(2000, 0, 640, 480)
        assert(list_count >= 1,
            "fake_add class list signal must stay synchronous")
        return true
    end,

    -- Step 4: a removed screen is reported invalid, so queued signals for
    -- it get dropped by screen_checker instead of running on a zombie.
    function()
        fake_screen:fake_remove()
        assert(fake_screen.valid == false,
            "removed screen must report valid == false, got "
            .. tostring(fake_screen.valid))
        assert(screen[fake_screen] == nil,
            "screen[removed] must be nil so get_screen() guards catch it")
        local ok = pcall(function() return fake_screen.geometry end)
        assert(not ok,
            "properties other than valid must raise on a removed screen")
        return true
    end,

    -- Step 5: a drain cycle passes with the removed screen still referenced.
    -- Reaching step 6 proves drain survived it.
    function() return true end,
    function() return true end,
}

runner.run_steps(steps)
