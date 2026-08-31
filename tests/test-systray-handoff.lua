---------------------------------------------------------------------------
-- Test: moving the systray repaints the host it left
--
-- The icons composite into the host drawin's content entry rather than
-- living in their own scene tree, so dropping the tray has to repaint the
-- old host. awesome.systray() reports the current parent, and the kickout
-- path runs drawin_refresh_drawable() on the drawin it left.
--
-- With no tray client connected systray_composite() paints nothing, so this
-- covers the ownership handoff and the repaint call, not the pixels.
---------------------------------------------------------------------------

local runner = require("_runner")
local wibox = require("wibox")

local a, b

local function parent()
    local _, p = awesome.systray()
    return p
end

local steps = {
    function()
        a = wibox({ x = 0, y = 0, width = 200, height = 24,
                    bg = "#111111", visible = true })
        a:setup({ widget = wibox.widget.textbox, text = "a" })
        b = wibox({ x = 0, y = 40, width = 200, height = 24,
                    bg = "#222222", visible = true })
        b:setup({ widget = wibox.widget.textbox, text = "b" })
        return true
    end,

    -- Both need pixels before the kickout repaint has anything to re-feed.
    function()
        local order = awesome._test_declare_order(screen[1])
        local seen = {}
        for _, o in ipairs(order) do seen[o] = true end
        return (seen[a.drawin] and seen[b.drawin]) or nil
    end,

    function()
        awesome.systray(a.drawin, 0, 0, 16, true, "#000000", false, 0, 1)
        assert(parent() == a.drawin, "systray did not land on a")
        return true
    end,

    -- The handoff kicks a out, which repaints it.
    function()
        awesome.systray(b.drawin, 0, 0, 16, true, "#000000", false, 0, 1)
        assert(parent() == b.drawin, "systray did not move to b")
        return true
    end,

    -- The one-argument form is a bare kickout.
    function()
        awesome.systray(b.drawin)
        assert(parent() == nil, "systray still has a parent after kickout")
        return true
    end,

    -- Kicking out a drawin that does not host the tray is a no-op.
    function()
        awesome.systray(a.drawin)
        assert(parent() == nil, "kickout of a non-host set a parent")
        io.stderr:write("[PASS] systray handoff and kickout\n")
        return true
    end,

    function()
        a.visible = false
        b.visible = false
        return true
    end,
}

runner.run_steps(steps)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
