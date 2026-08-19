---------------------------------------------------------------------------
--- Extra mouse buttons map to X11 numbers 8/9/10/11, matching X11's
--- libinput driver (8 + code - BTN_SIDE).
---
--- BTN_FORWARD/BTN_BACK (277/278) used to fall through the generic
--- translation and come out as buttons 6/7, colliding with the synthesized
--- horizontal-scroll buttons.
---
--- Input is injected with test-virtual-pointer-client so it traverses the
--- real buttonpress() path.
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

    local fired = {}
    local bindings = {}
    for _, b in ipairs({ 6, 7, 8, 9, 10, 11 }) do
        fired[b] = 0
        bindings[#bindings + 1] = awful.button({ }, b, function()
            fired[b] = fired[b] + 1
        end)
    end
    awful.mouse.append_global_mousebindings(bindings)
    async.sleep(0.2)

    local function click(name, button)
        local before = fired[button]
        awful.spawn(string.format("%s click %d %d %d %d %s",
                                  VPOINTER, cx, cy, sg.width, sg.height, name))
        async.wait_for_condition(function() return fired[button] > before end, 5)
    end

    click("side", 8)
    assert(fired[8] == 1, "side did not fire button 8 (" .. fired[8] .. ")")

    click("extra", 9)
    assert(fired[9] == 1, "extra did not fire button 9 (" .. fired[9] .. ")")

    click("forward", 10)
    assert(fired[10] == 1, "forward did not fire button 10 (" .. fired[10] .. ")")

    click("back", 11)
    assert(fired[11] == 1, "back did not fire button 11 (" .. fired[11] .. ")")

    -- The regression: forward/back must not masquerade as horizontal scroll.
    assert(fired[6] == 0, "button 6 fired for an extra button (" .. fired[6] .. ")")
    assert(fired[7] == 0, "button 7 fired for an extra button (" .. fired[7] .. ")")

    io.stderr:write("[ALL TESTS] PASS\n")
    runner.done()
end)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
