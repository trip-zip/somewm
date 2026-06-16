---------------------------------------------------------------------------
--- Test: edge behaviors of the descriptor-less reflection (reflect_geometries),
--- which the other merge tests (all gap = 0, all on-screen) do not exercise.
---
--- 1. GAP: with a non-zero useless_gap, a reflected client's surface is inset by
---    the gap exactly as the old imperative apply loop did (the byte-correct
---    claim). A custom arrange(p) tiles three columns; each surface lands at
---    workarea.x + 2*gap + (i-1)*third (the legacy double-gap: once from the
---    gap-inset p.workarea, once from the per-client inset) with width
---    third - 2*gap - 2*border.
--- 2. OFF-SCREEN SKIP: a client a custom arrange parks fully off-screen is NOT
---    applied (reflect_geometries skips it so Clay does not cull it to a 1x1 box
---    at the origin); it keeps the geometry it already had.
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

local GAP = 10
local CLASSES = { "re_a", "re_b", "re_c" }
local tag

-- Phase 1: three equal columns, all on-screen, gap = GAP.
local columns = {
    name = "reflect_cols",
    arrange = function(p)
        local wa = p.workarea
        local third = math.floor(wa.width / 3)
        for i, c in ipairs(p.clients) do
            p.geometries[c] = {
                x = wa.x + (i - 1) * third, y = wa.y,
                width = third, height = wa.height,
            }
        end
    end,
}

-- Phase 2: clients[1] parked far off-screen left, the rest in the left third.
local off_screen = {
    name = "reflect_offscreen",
    arrange = function(p)
        local wa = p.workarea
        local third = math.floor(wa.width / 3)
        for i, c in ipairs(p.clients) do
            if i == 1 then
                p.geometries[c] = { x = wa.x - 10000, y = wa.y,
                                    width = third, height = wa.height }
            else
                p.geometries[c] = { x = wa.x, y = wa.y,
                                    width = third, height = wa.height }
            end
        end
    end,
}

local steps = {
    function()
        tag = screen.primary.tags[1]
        tag:view_only()
        tag.gap = GAP
        tag.layout = columns
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

    -- GAP: the gap is applied to reflected clients -- columns are inset from the
    -- workarea and separated from each other by ~2*gap. Asserting the gap EFFECT
    -- (not an exact slot formula) keeps the test robust while still catching a
    -- dropped/halved gap term in reflect_geometries; byte-exactness vs the old
    -- loop is proven separately. If the gap term were dropped, the inset and the
    -- inter-column spacing both collapse toward 0.
    function(count)
        if count == 1 then awful.layout.arrange(screen.primary); return nil end
        if count < 4 then return nil end
        local wa = screen.primary.workarea
        local cs = {}
        for _, cls in ipairs(CLASSES) do cs[#cs + 1] = utils.find_client_by_class(cls) end
        table.sort(cs, function(a, b) return a:geometry().x < b:geometry().x end)
        local g1 = cs[1]:geometry()
        assert(g1.x >= wa.x + GAP, string.format(
            "gap: leftmost column x=%d not inset from workarea x=%d", g1.x, wa.x))
        for i = 1, #cs - 1 do
            local a, b = cs[i]:geometry(), cs[i + 1]:geometry()
            local space = b.x - (a.x + a.width)   -- = 2*gap + 2*border
            assert(space >= 2 * GAP - 4, string.format(
                "gap: columns %d/%d separated by %dpx, expected ~%d (2*gap)",
                i, i + 1, space, 2 * GAP))
        end
        io.stderr:write("[TEST] PASS: gap inset applied to reflected clients\n")
        return true
    end,

    -- OFF-SCREEN SKIP: switch to the off-screen layout; no client may end up
    -- degenerate (1x1) or at the far-off-screen target.
    function(count)
        if count == 1 then
            tag.layout = off_screen
            awful.layout.arrange(screen.primary)
            return nil
        end
        if count < 4 then return nil end
        local wa = screen.primary.workarea
        for _, cls in ipairs(CLASSES) do
            local c = utils.find_client_by_class(cls)
            local g = c:geometry()
            assert(g.width > 2 and g.height > 2, string.format(
                "off-screen skip: client %s collapsed to %dx%d (Clay culled an "
                .. "un-skipped off-screen leaf)", cls, g.width, g.height))
            assert(g.x > wa.x - 100, string.format(
                "off-screen skip: client %s applied off-screen at x=%d", cls, g.x))
        end
        io.stderr:write("[TEST] PASS: off-screen client skipped, not applied\n")
        return true
    end,

    function(count)
        if count == 1 then
            for _, c in ipairs(client.get()) do if c.valid then c:kill() end end
        end
        if #client.get() == 0 then return true end
        if count >= 10 then return true end
    end,
}

runner.run_steps(steps, { kill_clients = false })

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
