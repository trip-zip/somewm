-- Idle timeouts fire once across redraws and respect inhibition (issue 962).
-- timeout: 20

local runner = require("_runner")
local awful = require("awful")
local gears = require("gears")
local wibox = require("wibox")

local textbox = wibox.widget.textbox("init")
local box = wibox {
    x = 0, y = 0, width = 120, height = 24,
    bg = "#000000", visible = true,
    screen = awful.screen.focused(),
    widget = textbox,
}
local ticks = 0
local ticking = gears.timer {
    timeout = 0.1,
    callback = function()
        ticks = ticks + 1
        textbox.text = "tick " .. ticks
    end,
}
local callbacks = 0
local failures = {}

-- Defer failure until cleanup so every case reports its callback count.
local function check(ok, message)
    if not ok then failures[#failures + 1] = message end
    io.stderr:write((ok and "[PASS] " or "[FAIL] ") .. message .. "\n")
end

local function arm()
    callbacks = 0
    awesome.set_idle_timeout("redraw", 1, function()
        callbacks = callbacks + 1
    end)
end

runner.run_steps({
    function()
        awesome.clear_all_idle_timeouts()
        awesome.idle_inhibit = false
        ticking:start()
        arm()
        return true
    end,
    function(count)
        if callbacks == 0 and count < 31 then return end
        check(callbacks > 0,
            "case 1: fires within 3s while ticking, count " .. callbacks)
        ticking:stop()
        arm()
        return true
    end,
    function(count)
        if callbacks == 0 and count < 31 then return end
        check(callbacks == 1,
            "case 2: fires before the single redraw, count " .. callbacks)
        textbox.text = "single redraw"
        return true
    end,
    function(count)
        if count < 26 then return end
        check(callbacks == 1,
            "case 2: stays fired 2.5s after a single redraw, count " .. callbacks)
        ticking:start()
        awesome.idle_inhibit = true
        arm()
        return true
    end,
    function(count)
        if count < 26 then return end
        check(callbacks == 0,
            "case 3: inhibited for 2.5s while ticking, count " .. callbacks)
        awesome.idle_inhibit = false
        return true
    end,
    function(count)
        if callbacks == 0 and count < 31 then return end
        check(callbacks > 0,
            "case 3: fires within 3s after uninhibiting while ticking, count " .. callbacks)
        ticking:stop()
        awesome.clear_all_idle_timeouts()
        awesome.idle_inhibit = false
        box.visible = false
        assert(#failures == 0, table.concat(failures, "\n"))
        return true
    end,
}, { wait_per_step = 5, kill_clients = false })
