-- Test: Notification position bugs.
--
-- Bug #3170 - Box has no fallback when notification weak ref is cleared:
--   box.lua:305 stores the notification in a weak table ({__mode="v"}).
--   box.lua:314-322 get_position() returns the notification's position, but
--   when the weak ref is nil (after GC), it returns fallback "top_right"
--   instead of the original position. The box has no cached position.
--
--   In normal destroy flow, finish() runs before GC (signal handler has stack
--   ref to notification), so cleanup works. But if get_position() is called
--   after the notification ref is lost for any reason, the box reports the
--   wrong position. This is a design flaw: the box should cache its position.
--
--   Test approach: Create a box at "top_left", clear its notification
--   reference (simulating what happens after GC), verify get_position()
--   returns the wrong value.
--
-- Bug #3035 - middle position shifts on update:
--   box.lua:95-96 computes align = position:match("_(.*)") which for
--   "top_middle" gives "middle". The gsub("left","front"):gsub("right","back")
--   doesn't match, leaving align = "middle". awful.placement.next_to with
--   anchor "middle" behaves incorrectly.

local naughty = require("naughty")
local notification = require("naughty.notification")
local nbox = require("naughty.layout.box")
local runner = require("_runner")

-- Register a display handler
naughty.connect_signal("request::display", function(n)
    nbox { notification = n }
end)

local steps = {}

-- Bug #3170: Box returns wrong position when notification ref is lost.
-- The box stores the notification in a weak table. If the notification is
-- collected or the reference is otherwise lost, get_position() returns
-- "top_right" instead of the original position. This means finish() would
-- look in the wrong position list and fail to clean up the box.
table.insert(steps, function()
    -- Create notification at "top_left"
    local n = notification {
        title    = "Bug 3170 - position fallback",
        text     = "Box should remember its position",
        position = "top_left",
        timeout  = 0,
    }

    assert(n, "notification was not created")

    -- Create an explicit box
    local b = nbox { notification = n }
    assert(b, "box was not created")
    assert(b:get_position() == "top_left",
        "box position should be top_left initially")

    -- Simulate what happens when the notification's weak ref is cleared
    -- (e.g., after GC collects the notification). This directly exposes
    -- the design flaw: the box has no cached position.
    b._private.notification = setmetatable({}, {__mode = "v"})

    -- BUG #3170: get_position() now returns "top_right" (the hardcoded
    -- fallback at box.lua:321) instead of "top_left". If finish() runs
    -- in this state, it would look for this box in by_position[s]["top_right"]
    -- instead of by_position[s]["top_left"], failing to clean it up.
    local pos = b:get_position()
    assert(pos == "top_left",
        string.format(
            "BUG #3170: box position should be 'top_left' after notification "..
            "ref is lost, got '%s' - get_position() falls back to 'top_right' "..
            "because box has no cached position. finish() would look in the "..
            "wrong position list and fail to remove this ghost box.",
            tostring(pos)))

    -- Cleanup
    n:destroy()

    return true
end)

-- Bug #3035: Notification position "middle" anchor not handled correctly.
-- The update_position function at box.lua:93-96 computes the anchor from
-- the position name. For "top_middle", align becomes "middle" which is not
-- transformed by the gsub chain and isn't a valid anchor for awful.placement.
table.insert(steps, function()
    -- Create two notifications at "top_middle" to test stacking
    local n1 = notification {
        title    = "Bug 3035 - middle 1",
        text     = "First notification at top_middle",
        position = "top_middle",
        timeout  = 0,
    }
    local n2 = notification {
        title    = "Bug 3035 - middle 2",
        text     = "Second notification at top_middle",
        position = "top_middle",
        timeout  = 0,
    }

    -- Create boxes to track geometry
    local b1 = nbox { notification = n1 }
    local b2 = nbox { notification = n2 }

    if not (b1 and b2 and b1:geometry() and b2:geometry()) then
        return -- wait for layout
    end

    local g1_before = b1:geometry()

    -- Trigger an update by changing text
    n1.text = "Updated text for middle position test"

    local g1_after = b1:geometry()

    -- BUG #3035: The x position may shift because "middle" isn't a valid
    -- anchor for awful.placement.next_to. The first widget placement uses
    -- position:gsub("_middle", "") which strips "_middle", but subsequent
    -- widgets use "middle" as anchor which causes incorrect positioning.
    assert(g1_after.x == g1_before.x,
        string.format(
            "BUG #3035: notification at top_middle shifted x position on "..
            "update: before=%d, after=%d - 'middle' anchor not handled "..
            "correctly by awful.placement",
            g1_before.x, g1_after.x))

    -- Cleanup
    n1:destroy()
    n2:destroy()

    return true
end)

runner.run_steps(steps, { kill_clients = false })
