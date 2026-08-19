---------------------------------------------------------------------------
--- Scroll wheel and side buttons during mousegrabber (parity with X11).
---
--- A scroll tick must reach the grabber callback as X11 buttons 4/5: a
--- press call with the flag set, immediately followed by a release call
--- with it cleared. BTN_SIDE/BTN_EXTRA are X11 buttons 8/9 and must not
--- fake the scroll flags (they used to be tracked in slots 4/5).
---
--- Input is injected with test-virtual-pointer-client so it traverses the
--- real axisnotify()/buttonpress() paths (root.fake_input bypasses them).
---------------------------------------------------------------------------

local runner = require("_runner")
local async  = require("_async")
local awful  = require("awful")
local utils  = require("_utils")

local VPOINTER = utils.binary_or_skip("./build-test/test-virtual-pointer-client")
if not VPOINTER then return end

runner.run_async(function()
    local sg = screen[1].geometry
    local cx = sg.x + math.floor(sg.width / 2)
    local cy = sg.y + math.floor(sg.height / 2)

    local records = {}
    mousegrabber.run(function(m)
        records[#records + 1] = { b4 = m.buttons[4], b5 = m.buttons[5] }
        return true
    end, nil)
    assert(mousegrabber.isrunning(), "mousegrabber did not start")

    local function inject(action, arg)
        records = {}
        awful.spawn(string.format("%s %s %d %d %d %d %s",
                                  VPOINTER, action, cx, cy, sg.width, sg.height, arg))
        -- 2 motion callbacks (client double-sends the move) + press + release
        async.wait_for_condition(function() return #records >= 4 end, 5)
        return records
    end

    -- One scroll tick: press call with the flag set, then a release call.
    local function assert_tick(recs, flag, label)
        local press
        for i, r in ipairs(recs) do
            if r[flag] then press = i break end
        end
        assert(press, label .. ": grabber never saw " .. flag .. " pressed")
        local rel = recs[press + 1]
        assert(rel and not rel[flag],
            label .. ": no release call after the " .. flag .. " press")
    end

    local recs = inject("scroll", "down")
    assert_tick(recs, "b5", "scroll down")
    for _, r in ipairs(recs) do
        assert(not r.b4, "scroll down: buttons[4] flagged")
    end

    recs = inject("scroll", "up")
    assert_tick(recs, "b4", "scroll up")
    for _, r in ipairs(recs) do
        assert(not r.b5, "scroll up: buttons[5] flagged")
    end

    -- BTN_SIDE (X11 button 8) must not appear as scroll (regression: it was
    -- tracked in slot 4).
    recs = inject("click", "side")
    assert(#recs > 0, "side click: grabber saw no events")
    for _, r in ipairs(recs) do
        assert(not r.b4 and not r.b5, "side click: flagged as scroll")
    end

    mousegrabber.stop()
    assert(not mousegrabber.isrunning(), "mousegrabber did not stop")

    io.stderr:write("[ALL TESTS] PASS\n")
    runner.done()
end)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
