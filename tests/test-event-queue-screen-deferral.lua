---------------------------------------------------------------------------
--- Test: topology signals from C paths defer to the frame boundary
--
-- Verifies:
--   1. Screen property::geometry triggered by a C-side layout change
--      (output position -> updatemons) is NOT delivered synchronously;
--      it arrives at the next some_refresh() drain, carrying the old
--      geometry argument through the queue.
--   2. Lua-initiated paths bypass the queue: screen.fake_add delivers
--      the class "list" signal synchronously.
---------------------------------------------------------------------------

local runner = require("_runner")

local geo_count = 0
local geo_at_set
local geo_old_arg

local list_count = 0

local fake_screen

local steps = {
    -- Step 1: C-initiated geometry change is not delivered synchronously
    function()
        local s = screen[1]
        s:connect_signal("property::geometry", function(_, old)
            geo_count = geo_count + 1
            geo_old_arg = old
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

    -- Step 4: cleanup
    function()
        fake_screen:fake_remove()
        return true
    end,
}

runner.run_steps(steps)
