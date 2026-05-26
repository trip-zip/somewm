---------------------------------------------------------------------------
--- Test: the magnifier layout centers the focused client over the tiled
--- background in ONE solve (Step 4).
---
--- Before Step 4 magnifier ran two solves per arrange (the background column,
--- then the centered overlay). The floating-to-root primitive lets it emit
--- one tree: the non-focused clients tile in a column, the focused client
--- overlays them as a centered CLAY_ATTACH_TO_ROOT node. So an arrange now
--- drives exactly one "magnifier" solve, and the focused client sits centered
--- at sqrt(master_width_factor) of the workarea.
---------------------------------------------------------------------------

local runner = require("_runner")
local test_client = require("_client")
local utils = require("_utils")
local awful = require("awful")

if not test_client.is_available() then
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local clay = require("awful.layout.clay")

local function counts() return _somewm_clay.get_solve_counts() end

local CLASSES = { "mag_a", "mag_b", "mag_c" }
local tag, focused

local steps = {
    function()
        tag = screen.primary.tags[1]
        tag:view_only()
        tag.gap = 0
        tag.master_width_factor = 0.25  -- sqrt = 0.5: focused fills half the wa
        tag.layout = clay.magnifier
        return true
    end,
    function(count)
        if count == 1 then
            for _, cls in ipairs(CLASSES) do test_client(cls) end
        end
        local n = 0
        for _, cls in ipairs(CLASSES) do
            if utils.find_client_by_class(cls) then n = n + 1 end
        end
        return n == #CLASSES and true or nil
    end,
    -- Focus one client (the one that should be magnified).
    function(count)
        if count == 1 then
            focused = utils.find_client_by_class("mag_b")
            focused:emit_signal("request::activate", "test", { raise = true })
        end
        return client.focus == focused and true or nil
    end,
    -- Keep mag_b focused and re-arrange until it is the magnified (centered)
    -- client: the magnifier magnifies client.focus, which can drift under load,
    -- so re-assert focus each iteration. compose_screen and magnifier each run
    -- once per arrange, so "one solve per arrange" stays magnifier ==
    -- compose_screen (was 2x before Step 4) regardless of how many arranges
    -- this takes, and is robust to the cascade applying geometry triggers.
    function(count)
        if count == 1 then _somewm_clay.reset_solve_counts() end
        if client.focus ~= focused then
            focused:emit_signal("request::activate", "test", { raise = true })
        end
        awful.layout.arrange(screen.primary)

        local wa = screen.primary.workarea
        local bw = focused.border_width or 0
        local g  = focused:geometry()
        local exp_x = wa.x + math.floor(wa.width * 0.25)
        -- Wait for a post-reset arrange (magnifier >= 1) as well as the centered
        -- geometry, so the counters reflect this measurement, not the reset.
        if (counts().magnifier < 1 or client.focus ~= focused
            or math.abs(g.x - exp_x) > 2 * bw + 4) and count < 20 then
            return nil
        end

        local c = counts()
        io.stderr:write(string.format(
            "[TEST] magnifier: magnifier=%d compose=%d preset=%d merged=%d x=%d w=%d\n",
            c.magnifier, c.compose_screen, c.preset, c.merged, g.x, g.width))
        assert(client.focus == focused, "the intended client should be focused")
        assert(c.magnifier >= 1, "magnifier should drive a magnifier solve")
        assert(c.preset == 0 and c.merged == 0,
            "magnifier should not use the preset or merged paths")
        assert(c.magnifier == c.compose_screen,
            "magnifier should solve once per arrange (was two passes)")
        utils.assert_geometry(g, {
            x = exp_x,
            y = wa.y + math.floor(wa.height * 0.25),
            width  = math.floor(wa.width  * 0.5) - 2 * bw,
            height = math.floor(wa.height * 0.5) - 2 * bw,
        }, 2 * bw + 4)
        io.stderr:write(
            "[TEST] PASS: magnifier centers the focused client in one solve\n")
        return true
    end,
    -- Cleanup.
    function(count)
        if count == 1 then
            for _, c in ipairs(client.get()) do
                if c.valid then c:kill() end
            end
        end
        if #client.get() == 0 then return true end
        if count >= 10 then return true end
    end,
}

runner.run_steps(steps, { kill_clients = false })

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
