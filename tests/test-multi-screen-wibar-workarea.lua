---------------------------------------------------------------------------
-- Each screen's workarea must reflect its own wibar's strut.
--
-- Regression: with two screens and one wibar per screen, screen 2's
-- workarea was sometimes left equal to its full geometry (titlebars on
-- screen 2 ended up under the wibar) while screen 1 was correct.
---------------------------------------------------------------------------

local runner = require("_runner")
local awful = require("awful")
local gtimer = require("gears.timer")

local primary = screen.primary
local fake_screen
local wb1, wb2
local settled = false

local function workarea_shrunk(s, wibar_height)
    return s.workarea.height == s.geometry.height - wibar_height
       and s.workarea.y      == s.geometry.y      + wibar_height
end

local steps = {
    function()
        fake_screen = screen.fake_add(2000, 0, 800, 600)
        assert(fake_screen and fake_screen.valid, "fake_add failed")
        assert(screen.count() >= 2, "need >=2 screens")

        wb1 = awful.wibar({ position = "top", screen = primary, height = 32 })
        wb2 = awful.wibar({ position = "top", screen = fake_screen, height = 32 })
        assert(wb1.visible and wb2.visible, "both wibars must be visible")

        gtimer.delayed_call(function() settled = true end)
        return true
    end,

    function()
        if not settled then return nil end
        return true
    end,

    function()
        assert(workarea_shrunk(primary, 32),
            string.format("primary workarea not shrunk: geom=%dx%d wa=%dx%d+%d+%d",
                primary.geometry.width, primary.geometry.height,
                primary.workarea.width, primary.workarea.height,
                primary.workarea.x, primary.workarea.y))

        assert(workarea_shrunk(fake_screen, 32),
            string.format("fake_screen workarea not shrunk: geom=%dx%d wa=%dx%d+%d+%d",
                fake_screen.geometry.width, fake_screen.geometry.height,
                fake_screen.workarea.width, fake_screen.workarea.height,
                fake_screen.workarea.x, fake_screen.workarea.y))

        wb1.visible = false
        wb2.visible = false
        if fake_screen and fake_screen.valid then fake_screen:fake_remove() end
        return true
    end,
}

runner.run_steps(steps)
