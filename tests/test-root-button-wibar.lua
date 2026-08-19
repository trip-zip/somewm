---------------------------------------------------------------------------
--- Regression test: a right click on a wibar must not fire root bindings.
---
--- buttonpress() ran the root button check whenever no client and no layer
--- surface was under the cursor, and a wibar click sets neither: the root
--- binding (the main menu in the default config) fired on top of whatever
--- the wibar itself did with the click.
---
--- The click is injected with test-virtual-pointer-client so it traverses the
--- real buttonpress() path (root.fake_input bypasses it).
---------------------------------------------------------------------------

local runner = require("_runner")
local async  = require("_async")
local awful  = require("awful")
local utils  = require("_utils")

local VPOINTER = utils.binary_or_skip("./build-test/test-virtual-pointer-client")
if not VPOINTER then return end

runner.run_async(function()
    local s  = screen[1]
    local sg = s.geometry

    local bar = awful.wibar { position = "top", screen = s, height = 20 }
    local bar_presses = 0
    bar:connect_signal("button::press", function() bar_presses = bar_presses + 1 end)

    local root_presses = 0
    awful.mouse.append_global_mousebindings({
        awful.button({ }, 3, function() root_presses = root_presses + 1 end),
    })
    async.sleep(0.2)

    local bg = bar:geometry()
    assert(bg.height > 0, "wibar has no geometry")

    local function right_click(x, y)
        awful.spawn(string.format("%s click %d %d %d %d right",
                                  VPOINTER, x, y, sg.width, sg.height))
        async.sleep(1)
    end

    -- Right click on the wibar: the wibar sees it, the root binding must not.
    right_click(bg.x + math.floor(bg.width / 2), bg.y + math.floor(bg.height / 2))
    assert(bar_presses > 0, "click never reached the wibar")
    assert(root_presses == 0,
        "root button binding fired for a click on the wibar (" .. root_presses .. ")")

    -- Right click on empty desktop: the root binding still works.
    right_click(sg.x + math.floor(sg.width / 2), sg.y + math.floor(sg.height / 2))
    assert(root_presses == 1,
        "root button binding did not fire on empty desktop (" .. root_presses .. ")")

    io.stderr:write("[ALL TESTS] PASS\n")

    bar.visible = false
    runner.done()
end)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
