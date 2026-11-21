-- timeout: 30
---------------------------------------------------------------------------
--- Pointer scenarios 16: which bindings a press, a release and a scroll tick
--- fire, by what is under the pointer.
---
--- One owner per event: a wibox, a window, the desktop, or a foreign surface
--- (a layer surface, an X11 menu) that has no bindings. A release belongs to
--- the owner of its press. A press on the desktop is the exception AwesomeWM
--- has: its release fires root bindings only over the desktop, the wibox's
--- over a wibox, and nothing over a window. Modifiers match exactly, or "Any".
---
--- 16a click on the desktop
--- 16b click on a wibox
--- 16c press on a wibox, release on the desktop
--- 16d press on the desktop, release on a wibox
--- 16e press on the desktop, release on a window
--- 16f press on a window, release on the desktop
--- 16g click on a layer surface
--- 16h scroll over a layer surface
--- 16i scroll over a window
--- 16j root binding with no modifiers while Mod4 is held
--- 16k root binding with the "Any" modifier
--- 16m wibox binding with the "Any" modifier fires once per press
---
--- (tests/_pointer_probe.lua. The X11 menu cases are in
--- tests/test-xwayland-pointer-target.lua.)
---------------------------------------------------------------------------

local runner = require("_runner")
local async  = require("_async")
local awful  = require("awful")
local wibox  = require("wibox")
local probe  = require("_pointer_probe")

if probe.missing() then return end

local DESKTOP = { 1000, 600 }
local WINDOW  = { x = 300, y = 100, width = 300, height = 250 }
local BOX     = { x = 100, y = 480, width = 200, height = 100 }
local IN_BOX  = { BOX.x + 100, BOX.y + 50 }

local counts = {}
local function bump(key)
    return function() counts[key] = (counts[key] or 0) + 1 end
end

--- Compare the counters with what a scenario expects. A key the scenario
--- does not name must be 0.
local function expect(want)
    local ok, parts, seen = true, {}, {}
    for key, n in pairs(want) do
        seen[key] = true
        if (counts[key] or 0) ~= n then ok = false end
        parts[#parts + 1] = string.format("%s=%d (want %d)", key, counts[key] or 0, n)
    end
    for key, n in pairs(counts) do
        if not seen[key] and n ~= 0 then
            ok = false
            parts[#parts + 1] = string.format("%s=%d (want 0)", key, n)
        end
    end
    table.sort(parts)
    counts = {}
    return ok, #parts > 0 and table.concat(parts, ", ") or "nothing"
end

--- A click on the desktop while Mod4 is held.
local function click_with_mod4(button)
    root.fake_input("key_press", "Super_L")
    async.sleep(0.1)
    local ran, err = pcall(probe.run, "click", DESKTOP, button)
    root.fake_input("key_release", "Super_L")
    async.sleep(0.1)
    assert(ran, err)
end

runner.run_async(function()
    awful.mouse.append_global_mousebindings({
        awful.button({ }, 1, bump("root_press_1"), bump("root_release_1")),
        awful.button({ }, 3, bump("root_press_3")),
        awful.button({ }, 5, bump("root_press_5")),
        awful.button({ "Any" }, 2, bump("root_any_press_2")),
    })
    client.connect_signal("button::press", function(_, _, _, button)
        bump("window_press_" .. button)()
    end)
    client.connect_signal("button::release", function(_, _, _, button)
        bump("window_release_" .. button)()
    end)
    local box = wibox { x = BOX.x, y = BOX.y, width = BOX.width, height = BOX.height,
                        visible = true, bg = "#444444" }
    box:buttons({
        awful.button({ }, 1, bump("box_press_1"), bump("box_release_1")),
        awful.button({ "Any" }, 3, bump("box_any_press_3")),
    })
    async.sleep(0.3)

    probe.scenario("16a", "click on the desktop", function()
        probe.run("click", DESKTOP, "left")
        return expect { root_press_1 = 1, root_release_1 = 1 }
    end)

    probe.scenario("16b", "click on a wibox", function()
        probe.run("click", IN_BOX, "left")
        return expect { box_press_1 = 1, box_release_1 = 1 }
    end)

    probe.scenario("16c", "press on a wibox, release on the desktop", function()
        probe.run("drag", { IN_BOX[1], IN_BOX[2], DESKTOP[1], DESKTOP[2] }, 150, "left")
        return expect { box_press_1 = 1, box_release_1 = 1 }
    end)

    probe.scenario("16d", "press on the desktop, release on a wibox", function()
        probe.run("drag", { DESKTOP[1], DESKTOP[2], IN_BOX[1], IN_BOX[2] }, 150, "left")
        return expect { root_press_1 = 1, box_release_1 = 1 }
    end)

    probe.scenario("16e", "press on the desktop, release on a window", function()
        local w = probe.wayland("s16e_window", WINDOW)
        local x, y = probe.center(w)
        probe.run("drag", { DESKTOP[1], DESKTOP[2], x, y }, 150, "left")
        return expect { root_press_1 = 1 }
    end)

    probe.scenario("16f", "press on a window, release on the desktop", function()
        local w = probe.wayland("s16f_window", WINDOW)
        local x, y = probe.center(w)
        probe.run("drag", { x, y, DESKTOP[1], DESKTOP[2] }, 150, "left")
        return expect { window_press_1 = 1, window_release_1 = 1 }
    end)

    probe.scenario("16g", "click on a layer surface", function()
        local layer = probe.layer("s16g_layer", "--keyboard none --layer top --anchor bottom,right --size 200,100")
        probe.run("click", { probe.center(layer) }, "left")
        local ok, detail = expect { }
        -- A desktop click afterwards shows the root bindings still work.
        probe.run("click", DESKTOP, "left")
        local ok2, detail2 = expect { root_press_1 = 1, root_release_1 = 1 }
        return ok and ok2, "on the layer surface: " .. detail .. ". on the desktop: " .. detail2
    end)

    probe.scenario("16h", "scroll over a layer surface", function()
        local layer = probe.layer("s16h_layer", "--keyboard none --layer top --anchor bottom,right --size 200,100")
        probe.run("scroll", { probe.center(layer) }, "down")
        local ok, detail = expect { }
        probe.run("scroll", DESKTOP, "down")
        local ok2, detail2 = expect { root_press_5 = 1 }
        return ok and ok2, "over the layer surface: " .. detail .. ". over the desktop: " .. detail2
    end)

    probe.scenario("16i", "scroll over a window", function()
        local w = probe.wayland("s16i_window", WINDOW)
        local x, y = probe.center(w)
        probe.run("scroll", { x, y }, "down")
        return expect { window_press_5 = 1, window_release_5 = 1 }
    end)

    probe.scenario("16j", "root binding with no modifiers while Mod4 is held", function()
        click_with_mod4("right")
        local ok, detail = expect { }
        probe.run("click", DESKTOP, "right")
        local ok2, detail2 = expect { root_press_3 = 1 }
        return ok and ok2, "with Mod4: " .. detail .. ". without: " .. detail2
    end)

    probe.scenario("16k", "root binding with the Any modifier", function()
        probe.run("click", DESKTOP, "middle")
        local ok, detail = expect { root_any_press_2 = 1 }
        click_with_mod4("middle")
        local ok2, detail2 = expect { root_any_press_2 = 1 }
        return ok and ok2, "without a modifier: " .. detail .. ". with Mod4: " .. detail2
    end)

    probe.scenario("16m", "wibox binding with the Any modifier fires once", function()
        probe.run("click", IN_BOX, "right")
        return expect { box_any_press_3 = 1 }
    end)

    box.visible = false
    probe.finish()
    runner.done()
end)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
