---------------------------------------------------------------------------
--- Test: decorations folded into the merged screen solve (Stage 0).
---
--- A tiled client's borders/titlebars/surface are emitted as children of its
--- node in compose_screen's one solve; apply_geometry_to_wlroots then consumes
--- those boxes (clay_consume_merged_frame) instead of running the
--- per-client decoration solve. This test proves the consume path is active:
--- after a steady-state re-arrange of a tiled client carrying a titlebar, the
--- screen does a "merged" solve and the per-client "decoration" solve does NOT
--- fire (it would, on the fallback). It also checks the client still tiles
--- within the workarea (no geometry regression).
---
--- Floating/fullscreen clients keep the per-client decoration solve in this
--- stage (only the merged tiled subtree is tagged), so this test pins the
--- tiled path specifically.
---
--- Run: make test-one TEST=tests/test-clay-merged-decorations.lua
---------------------------------------------------------------------------

local runner = require("_runner")
local async  = require("_async")
local test_client = require("_client")
local awful  = require("awful")

if not test_client.is_available() then
    io.stderr:write("SKIP: no terminal available\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

runner.run_async(function()
    local s = screen.primary
    s.tags[1]:view_only()
    s.tags[1].layout = awful.layout.suit.tile
    async.sleep(0.1)

    test_client("decor_tiled")
    local c = async.wait_for_client("decor_tiled", 5)
    assert(c, "client did not appear")

    c.floating = false -- force the tiled (merge-capable) path regardless of rules
    c.border_width = 4 -- a real border so the thickness assertions below bite
    async.sleep(0.05)
    assert(not c.floating, "client should be tiled")

    -- A titlebar exercises titlebar box routing in the merged decoration tree.
    awful.titlebar(c, { size = 20, position = "top" })
    async.sleep(0.3) -- settle: merged_frame stamped with the titlebar size

    -- Steady state: a forced re-arrange should solve the screen once (merged)
    -- and the client's decorations should be consumed from that solve, so the
    -- per-client decoration fallback must NOT fire.
    _somewm_clay.reset_solve_counts()
    awful.layout.arrange(s)
    async.sleep(0.3)

    local cnt = _somewm_clay.get_solve_counts()
    io.stderr:write(string.format(
        "[TEST] merged=%d decoration=%d compose=%d total=%d\n",
        cnt.merged, cnt.decoration, cnt.compose_screen, cnt.total))

    assert(cnt.merged >= 1,
        "tiled client should be laid out in a merged screen solve")
    assert(cnt.decoration == 0, string.format(
        "tiled client decorations should come from the merged solve, not the "
        .. "per-client fallback (decoration=%d)", cnt.decoration))

    -- No geometry regression: the client still tiles within the workarea.
    local wa = s.workarea
    local g = c:geometry()
    assert(g.width > 0 and g.height > 0, "client must have a real size")
    assert(g.x >= wa.x - 1 and g.y >= wa.y - 1
        and g.x + g.width <= wa.x + wa.width + 1
        and g.y + g.height <= wa.y + wa.height + 1,
        string.format("client %dx%d@%d,%d should sit within workarea %dx%d@%d,%d",
            g.width, g.height, g.x, g.y, wa.width, wa.height, wa.x, wa.y))

    -- The merged consume path must position the decoration scene nodes too, not
    -- just compute boxes. Only a top titlebar (size 20) here, so the surface sits
    -- at (bw, bw + 20); borders carry the real thickness.
    local bw = c.border_width or 0
    local dg = _somewm_clay.client_frame_geometry(c)
    assert(dg.surface.x == bw and dg.surface.y == bw + 20, string.format(
        "[TEST] surface offset = %d,%d, expected %d,%d", dg.surface.x, dg.surface.y,
        bw, bw + 20))
    if bw > 0 then
        assert(dg.border[1].h == bw and dg.border[3].w == bw, string.format(
            "[TEST] border thickness must be bw=%d, got top.h=%d left.w=%d",
            bw, dg.border[1].h, dg.border[3].w))
    end
    assert(dg.titlebar[1].size == 20, "[TEST] top titlebar size should be 20")

    io.stderr:write("[TEST] PASS: tiled client decorations folded into merged solve\n")

    if c.valid then c:kill() end
    for _, pid in ipairs(test_client.get_spawned_pids()) do
        os.execute("kill -9 " .. pid .. " 2>/dev/null")
    end
    assert(async.wait_for_no_clients(5), "client did not close")
    runner.done()
end)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
