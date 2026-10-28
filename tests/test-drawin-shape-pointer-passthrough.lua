---------------------------------------------------------------------------
--- Pointer input outside a shaped drawin's mask passes through to what is
--- below it.
---
--- A non-ontop wibox stays in LyrWibox. A point its mask rejects used to make
--- xytonode() read the content buffer's drawable as a drawin: every motion
--- there either crashed or emitted mouse::enter on an unregistered drawin, and
--- the wibox below never saw the pointer.
---------------------------------------------------------------------------

local runner = require("_runner")
local async = require("_async")
local wibox = require("wibox")
local gears = require("gears")

local below, top
local entered = { below = 0, top = 0 }

-- Moves the pointer to (x, y) until the wibox named by key sees it. The warp
-- alone runs no hit test; the relative motions run motionnotify. Probing again
-- on each poll covers a wibox whose buffer is not attached yet.
local function reaches(x, y, key)
    return async.wait_for_condition(function()
        mouse.coords({ x = x, y = y })
        root.fake_input("motion_notify", true, 1, 0)
        root.fake_input("motion_notify", true, -1, 0)
        return entered[key] > 0
    end, 5)
end

runner.run_async(function()
    below = wibox {
        type = "desktop", x = 0, y = 0, width = 300, height = 300,
        bg = "#0000ff", visible = true,
    }
    top = wibox {
        x = 90, y = 90, width = 400, height = 120, bg = "#ff5500", visible = true,
        shape = function(cr, w, h) gears.shape.rounded_rect(cr, w, h, 40) end,
    }
    below:connect_signal("mouse::enter", function() entered.below = entered.below + 1 end)
    top:connect_signal("mouse::enter", function() entered.top = entered.top + 1 end)

    assert(async.wait_for_condition(function() return top.shape_bounding ~= nil end, 5),
        "the shaped wibox never got its bounding shape")

    assert(reaches(20, 20, "below"), "the desktop wibox never saw the pointer at (20, 20)")
    assert(reaches(290, 150, "top"), "the shaped wibox never saw the pointer at its center")

    -- (95, 95) is (5, 5) inside the shaped wibox, outside its 40px corner.
    entered.below, entered.top = 0, 0
    assert(reaches(95, 95, "below"),
        "the pointer in the masked corner did not reach the desktop wibox")
    assert(entered.top == 0, "the shaped wibox took the pointer in its masked corner")

    below.visible, top.visible = false, false
    runner.done()
end)
