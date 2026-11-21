-- timeout: 30
---------------------------------------------------------------------------
--- Pointer target scenarios with X11 windows (issue #965).
---
--- The X server picks the window under the pointer from its own stack. It
--- only agrees with the compositor's pick while that stack follows the
--- compositor's order: the window on top is on top there, and a window on a
--- hidden tag is below every visible one.
---
---  1. X11 window over an older X11 window
---  2. three X11 windows, the middle one raised
---  3. X11 window over a Wayland window
---  4. Wayland window over an X11 window
---  5. X11 menu (override-redirect) over its own window
--- 17. X11 window on a hidden tag in the same box as a visible X11 window
--- 16l an X11 menu that does not want focus has no bindings: a scroll over
---     it fires no root binding, a click fires no window signal, and the
---     menu still receives the click
---
--- Each scenario clicks a point where the windows overlap and reads which
--- client received the press (tests/_pointer_probe.lua).
---------------------------------------------------------------------------

local runner = require("_runner")
local async  = require("_async")
local awful  = require("awful")
local probe  = require("_pointer_probe")

if require("_utils").is_headless() then
    return runner.skip("XWayland tests require visual mode (HEADLESS=0)")
end
if probe.missing() then return end

local BIG, SMALL = probe.BIG, probe.SMALL

runner.run_async(function()
    probe.bind_click_to_activate()
    probe.warm_x11()

    probe.scenario(1, "X11 window over an older X11 window", function()
        local main = probe.x11("s1_main", BIG)
        local top = probe.x11("s1_top", SMALL)
        probe.raise_over(top, main)
        local x, y = probe.center(top)
        return probe.expect_press(function() probe.click(x, y) end, top)
    end)

    probe.scenario(2, "three X11 windows, the middle one raised", function()
        local first = probe.x11("s2_first", BIG)
        local middle = probe.x11("s2_middle", { x = 400, y = 150, width = 300, height = 250 })
        local last = probe.x11("s2_last", { x = 450, y = 200, width = 300, height = 250 })
        probe.raise_over(middle, first, last)
        -- (520, 300) is inside all three boxes.
        return probe.expect_press(function() probe.click(520, 300) end, middle)
    end)

    probe.scenario(3, "X11 window over a Wayland window", function()
        local below = probe.wayland("s3_wayland", BIG)
        local top = probe.x11("s3_x11", SMALL)
        probe.raise_over(top, below)
        local x, y = probe.center(top)
        return probe.expect_press(function() probe.click(x, y) end, top)
    end)

    probe.scenario(4, "Wayland window over an X11 window", function()
        local below = probe.x11("s4_x11", BIG)
        local top = probe.wayland("s4_wayland", SMALL)
        probe.raise_over(top, below)
        local x, y = probe.center(top)
        return probe.expect_press(function() probe.click(x, y) end, top)
    end)

    probe.scenario(5, "X11 menu over its own window", function()
        probe.x11("s5_main", BIG)
        local menu = probe.x11_override("s5_menu", SMALL)
        async.sleep(0.2)
        return probe.expect_press(function()
            probe.click(SMALL.x + SMALL.width / 2, SMALL.y + SMALL.height / 2)
        end, menu)
    end)

    probe.scenario(17, "X11 window on a hidden tag under a visible X11 window", function()
        -- The hidden window maps first, which leaves it above the visible
        -- one in an X stack that nobody reorders.
        local hidden = probe.x11("s17_hidden", BIG)
        local visible = probe.x11("s17_visible", BIG)
        local tag = awful.tag.add("hidden", { screen = hidden.c.screen })
        hidden.c:move_to_tag(tag)
        assert(async.wait_for_condition(function()
            return not hidden.c:isvisible()
        end, 3), "the first window is still visible")
        async.sleep(0.2)
        local x, y = probe.center(visible)
        return probe.expect_press(function() probe.click(x, y) end, visible)
    end)

    probe.scenario("16l", "X11 menu: no root or window bindings", function()
        local fired = {}
        local function bump(key)
            return function() fired[key] = (fired[key] or 0) + 1 end
        end
        awful.mouse.append_global_mousebindings({
            awful.button({ }, 5, bump("root_scroll")),
        })
        local function on_press(c) if c.name == "s16l_menu" then bump("menu_press")() end end
        local function on_release(c) if c.name == "s16l_menu" then bump("menu_release")() end end
        client.connect_signal("button::press", on_press)
        client.connect_signal("button::release", on_release)

        local menu = probe.x11_menu("s16l_menu", SMALL)
        async.sleep(0.2)
        local at = { SMALL.x + SMALL.width / 2, SMALL.y + SMALL.height / 2 }
        probe.run("scroll", at, "down")
        local over_menu = fired.root_scroll or 0
        -- X11 reports the scroll tick to the menu as a button press too.
        assert(probe.wait_for(menu, "^BUTTON press$"), "the scroll did not reach the menu")
        local before = probe.presses(menu)
        probe.run("click", at, "left")
        async.wait_for_condition(function() return probe.presses(menu) > before end, 3, 0.02)
        -- A scroll over the desktop shows the root binding works.
        probe.run("scroll", { 40, screen[1].geometry.height - 40 }, "down")
        local total = fired.root_scroll or 0
        client.disconnect_signal("button::press", on_press)
        client.disconnect_signal("button::release", on_release)

        local got = probe.presses(menu) - before
        return over_menu == 0 and total == 1 and got == 1
            and not fired.menu_press and not fired.menu_release,
            string.format("root scroll over the menu %d, over the desktop %d, window press "
                .. "signals %d, window release signals %d, clicks the menu received %d",
                over_menu, total - over_menu, fired.menu_press or 0,
                fired.menu_release or 0, got)
    end)

    probe.finish()
    runner.done()
end)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
