---------------------------------------------------------------------------
--- Test: floating + fullscreen clients are floating-to-root nodes in the
--- merged screen solve (Step 4), on the primary and a second output.
---
--- compose_screen reflects non-tiled clients (floating / fullscreen /
--- maximized) as CLAY_ATTACH_TO_ROOT nodes. The reflection is a no-op resize
--- (client_resize short-circuits on an equal area), so a floating client keeps
--- the geometry the user gave it: an arrange must not reposition it, even
--- after it is moved. A fullscreen client's box is screen.geometry (set by C),
--- so the root-attached reflection covers the whole screen incl. the wibar
--- region, not the wibar-inset workarea. The same holds on a non-primary
--- output, which checks compose_screen uses that screen's origin as the offset.
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

local tag, wb, fake
local c_tiled, c_float

local steps = {
    -- A top wibar so workarea is strictly inside screen.geometry: this lets
    -- the fullscreen assertion tell "covers screen" from "covers workarea".
    function()
        tag = screen.primary.tags[1]
        tag:view_only()
        tag.gap = 0
        tag.layout = clay.tile
        wb = awful.wibar { position = "top", screen = screen.primary, height = 24 }
        return wb.visible and true or nil
    end,

    -- Two clients: one stays tiled (keeps the tile layout merging), one floats.
    function(count)
        if count == 1 then
            test_client("cf_tiled")
            test_client("cf_float")
        end
        c_tiled = utils.find_client_by_class("cf_tiled")
        c_float = utils.find_client_by_class("cf_float")
        return (c_tiled and c_float) and true or nil
    end,

    -- Float one client at a distinctive box; a merged arrange must keep it
    -- exactly there (reflected, not tiled).
    function(count)
        if count == 1 then
            c_float.floating = true
            c_float:geometry {
                x = screen.primary.geometry.x + 120,
                y = screen.primary.geometry.y + 90,
                width = 240, height = 160,
            }
            _somewm_clay.reset_solve_counts()
            awful.layout.arrange(screen.primary)
            return nil
        end
        if counts().merged < 1 and count < 10 then return nil end
        assert(counts().merged >= 1,
            "tile tag should drive a merged solve that reflects the floater")
        utils.assert_geometry(c_float:geometry(), {
            x = screen.primary.geometry.x + 120,
            y = screen.primary.geometry.y + 90,
            width = 240, height = 160,
        }, 4)
        io.stderr:write(
            "[TEST] PASS: floating client keeps geometry through a merged arrange\n")
        return true
    end,

    -- Move the floater; the next arrange must reflect the new position, not
    -- snap it to a tiled slot.
    function(count)
        if count == 1 then
            c_float:geometry {
                x = screen.primary.geometry.x + 400,
                y = screen.primary.geometry.y + 250,
            }
            _somewm_clay.reset_solve_counts()
            awful.layout.arrange(screen.primary)
            return nil
        end
        if counts().merged < 1 and count < 10 then return nil end
        local g = c_float:geometry()
        assert(math.abs(g.x - (screen.primary.geometry.x + 400)) <= 4
            and math.abs(g.y - (screen.primary.geometry.y + 250)) <= 4,
            string.format("floater must stay where moved, got %d+%d", g.x, g.y))
        io.stderr:write(
            "[TEST] PASS: arrange reflects the floater's new position, does not tile it\n")
        return true
    end,

    -- Move the floater again, this time WITHOUT calling arrange: property::geometry
    -- is wired to the unconditional arrange, so the move must auto-re-solve. This
    -- step fails on the pre-Wiring floating-skip (merged stays 0).
    function(count)
        if count == 1 then
            c_float:geometry {
                x = screen.primary.geometry.x + 550,
                y = screen.primary.geometry.y + 320,
            }
            _somewm_clay.reset_solve_counts()
            return nil
        end
        if counts().merged < 1 and count < 12 then return nil end
        assert(counts().merged >= 1,
            "moving a floating client must auto re-solve via property::geometry")
        local g = c_float:geometry()
        assert(math.abs(g.x - (screen.primary.geometry.x + 550)) <= 4
            and math.abs(g.y - (screen.primary.geometry.y + 320)) <= 4,
            string.format("floater must stay where moved, got %d+%d", g.x, g.y))
        io.stderr:write(
            "[TEST] PASS: moving a floater auto-re-solves (no explicit arrange)\n")
        return true
    end,

    -- Fullscreen the tiled client; the reflection must cover screen.geometry
    -- (incl. the wibar band above the workarea), not the workarea.
    function(count)
        if count == 1 then
            c_float.floating = false
            c_tiled.fullscreen = true
            _somewm_clay.reset_solve_counts()
            awful.layout.arrange(screen.primary)
            return nil
        end
        if not c_tiled.fullscreen then return nil end
        if counts().merged < 1 and count < 10 then return nil end
        local geo = screen.primary.geometry
        local bw = c_tiled.border_width or 0
        utils.assert_geometry(c_tiled:geometry(),
            { x = geo.x, y = geo.y, width = geo.width, height = geo.height },
            2 * bw + 2)
        assert(c_tiled:geometry().y <= screen.primary.workarea.y - 1,
            "fullscreen client should cover the wibar region, not start at workarea")
        io.stderr:write(
            "[TEST] PASS: fullscreen client covers screen.geometry incl. wibar region\n")
        return true
    end,

    -- Multi-output: compose_screen runs per screen, so a second output gets its
    -- own workarea offset by that output's origin (not the primary's). The
    -- floating / fullscreen reflection is screen-agnostic (it uses s.geometry)
    -- and is exercised on the primary above; here we confirm the per-output
    -- offset and a fullscreen client covering the non-primary output.
    function(count)
        if count == 1 then
            c_tiled.fullscreen = false
            fake = screen.fake_add(1920, 0, 800, 600)
            assert(fake and fake.valid, "fake_add failed")
        end
        if screen.count() < 2 then return nil end
        awful.layout.arrange(fake)
        local wa = fake.workarea
        if (not wa or wa.x < fake.geometry.x - 4) and count < 12 then return nil end
        assert(wa and wa.x >= fake.geometry.x - 4
            and wa.x < fake.geometry.x + fake.geometry.width,
            "second output workarea should be offset by that output's origin")
        io.stderr:write(
            "[TEST] PASS: second output gets its own workarea offset\n")
        return true
    end,
    -- A fullscreen client on the second output covers that output, not the
    -- primary or the workarea (mirrors the cross-screen fullscreen pattern).
    function(count)
        if count == 1 then
            c_float:move_to_screen(fake)
            c_float.fullscreen = true
        end
        if (c_float.screen ~= fake or not c_float.fullscreen) and count < 15 then
            return nil
        end
        local geo = fake.geometry
        local bw  = c_float.border_width or 0
        local g   = c_float:geometry()
        if math.abs(g.width - geo.width) > 2 * bw + 4 and count < 15 then
            return nil
        end
        utils.assert_geometry(g,
            { x = geo.x, y = geo.y, width = geo.width, height = geo.height },
            2 * bw + 4)
        io.stderr:write(
            "[TEST] PASS: fullscreen on the second output covers that output\n")
        return true
    end,

    -- Cleanup.
    function(count)
        if count == 1 then
            if c_float.valid then c_float.fullscreen = false end
            if wb then wb.visible = false end
            for _, c in ipairs(client.get()) do
                if c.valid then c:kill() end
            end
        end
        if #client.get() == 0 then
            if fake and fake.valid then fake:fake_remove() end
            return true
        end
        if count >= 12 then
            if fake and fake.valid then fake:fake_remove() end
            return true
        end
    end,
}

runner.run_steps(steps, { kill_clients = false })

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
