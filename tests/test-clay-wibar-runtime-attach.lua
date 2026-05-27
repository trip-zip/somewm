---------------------------------------------------------------------------
--- Test: hiding a wibar at runtime (merged solve active) must not crash.
--
-- With a merge-capable layout and a tiled client, compose_screen applies its
-- results via clay_apply_all. When a wibar is hidden, its property::visible
-- handler runs reattach (compose_screen for the OTHER wibars) BEFORE the
-- now-invisible wibar is removed from s._clay_drawins, so the solve still emits
-- that wibar's drawin. Its drawin is no longer registered (invisible), so
-- luaA_drawin_set_geometry's luaA_object_push yields nil and the unguarded code
-- panics, taking the session down. This reproduces it and asserts survival.
---------------------------------------------------------------------------

local runner = require("_runner")
local test_client = require("_client")
local utils = require("_utils")
local awful = require("awful")
local wibox = require("wibox")

if not test_client.is_available() then
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local clay = require("awful.layout.clay")
local s = screen.primary
local tag = s.tags[1]
local bar_a, bar_b

local steps = {
    -- Merge-capable layout + two runtime wibars.
    function()
        tag:view_only()
        tag.layout = clay.tile
        bar_a = awful.wibar({ position = "top", screen = s, height = 22 })
        bar_a:set_widget(wibox.widget.textbox("wibar A"))
        bar_b = awful.wibar({ position = "bottom", screen = s, height = 18 })
        bar_b:set_widget(wibox.widget.textbox("wibar B"))
        io.stderr:write("[TEST] clay.tile + two runtime wibars\n")
        return true
    end,

    -- A tiled client makes the screen solve "merged" so clay_apply_all runs.
    function(count)
        if count == 1 then test_client("wibar_crash") end
        return utils.find_client_by_class("wibar_crash") and true or nil
    end,

    function()
        awful.layout.arrange(s)
        return true
    end,

    -- Hide one wibar: reattach -> compose_screen (merged) -> clay_apply_all with
    -- the hidden-but-still-tracked wibar's unregistered drawin -> nil -> panic
    -- on the unguarded code.
    function()
        bar_b.visible = false
        io.stderr:write("[TEST] hid wibar B\n")
        return true
    end,

    function()
        awful.layout.arrange(s)
        assert(screen.primary, "compositor should still be alive")
        local _ = screen.primary.workarea
        io.stderr:write("[TEST] PASS: runtime wibar hide did not crash\n")
        return true
    end,

    -- Cleanup.
    function(count)
        if count == 1 then
            for _, c in ipairs(client.get()) do if c.valid then c:kill() end end
        end
        if #client.get() == 0 then return true end
        if count >= 10 then
            for _, pid in ipairs(test_client.get_spawned_pids()) do
                os.execute("kill -9 " .. pid .. " 2>/dev/null")
            end
            return true
        end
    end,
}

runner.run_steps(steps, { kill_clients = false })
