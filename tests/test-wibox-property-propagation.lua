---------------------------------------------------------------------------
-- Test: wibox property setters (opacity, border_width, border_color)
-- propagate to the underlying C drawin so Wayland compositing sees them.
--
-- Before the fix, wibox["set_opacity"](self, v) stored v only on the Lua
-- wrapper; it never reached drawin->opacity, so wlr_scene_buffer_set_opacity
-- was never called. border_width and border_color had the same problem.
--
-- The fix propagates the value to self.drawin["_"..prop]. That relies on
-- every prop having an underscore-prefixed alias registered on the C side;
-- _opacity and _border_width had aliases, _border_color did not, so writes
-- to drawin._border_color fell through to the Lua miss-handler in
-- gears.object.properties which stashes them in _private - the value reads
-- back but never reaches drawin->border_color_parsed.
--
-- Each assertion below reads through a path that hits the C getter only
-- (plain names for border_*, _opacity for opacity since plain opacity is
-- not registered on the drawin class). The Lua miss-handler fallback path
-- would silently pass the old version of this test if we read the same
-- underscore name we wrote.
---------------------------------------------------------------------------

local runner = require("_runner")
local awful  = require("awful")
local wibox  = require("wibox")

local test_wibox

local steps = {
    function()
        test_wibox = wibox {
            x = 10, y = 10,
            width = 100, height = 50,
            bg = "#224466",
            visible = true,
            screen = awful.screen.focused(),
        }
        return true
    end,

    function()
        test_wibox.opacity = 0.5
        assert(test_wibox.drawin._opacity == 0.5,
            "opacity should reach drawin->opacity: got "
            .. tostring(test_wibox.drawin._opacity))
        io.stderr:write("[PASS] opacity propagates to drawin\n")
        return true
    end,

    function()
        test_wibox.border_width = 3
        assert(test_wibox.drawin.border_width == 3,
            "border_width should reach drawin->border_width: got "
            .. tostring(test_wibox.drawin.border_width))
        io.stderr:write("[PASS] border_width propagates to drawin\n")
        return true
    end,

    function()
        test_wibox.border_color = "#ff0000"
        local got = test_wibox.drawin.border_color
        assert(got and tostring(got):find("ff0000"),
            "border_color should reach drawin->border_color_parsed: got "
            .. tostring(got))
        io.stderr:write("[PASS] border_color propagates to drawin\n")
        return true
    end,

    function()
        if test_wibox then
            test_wibox.visible = false
            test_wibox = nil
        end
        return true
    end,
}

runner.run_steps(steps)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
