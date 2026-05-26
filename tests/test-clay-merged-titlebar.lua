---------------------------------------------------------------------------
--- Test: titlebar widget content folded into the merged screen solve (Step 2).
---
--- A tiled client's titlebar is a first-class part of the client model
--- (border( body( titlebars + surface ) )). Step 1 folded the titlebar BOX into
--- the merged solve; this step folds the titlebar's widget CONTENT in too, so a
--- titlebar's widgets are real nodes in the one tree, exactly like wibar widgets.
---
--- Verifies:
---   1. get_existing returns the client's titlebar drawable side-effect-free, and
---      its widget is the root we set (identity, so the placements key matches).
---   2. a titlebar content relayout drives a merged solve and fires ZERO per-
---      titlebar "wibox" forest solves, and the box still comes from the merged
---      solve (decoration == 0, not the per-client fallback).
---   3. the surface box and titlebar thickness do NOT move when titlebar content
---      reflows (R2: configure stability).
---   4. a titlebar widget still hit-tests (placements-derived matrices correct).
---   5. fullscreen drops the titlebar to box-only (size 0), no crash.
---   6. the solve never lazily creates a titlebar that was not requested.
---
--- Run: make test-one TEST=tests/test-clay-merged-titlebar.lua
---------------------------------------------------------------------------

local runner = require("_runner")
local async  = require("_async")
local test_client = require("_client")
local awful  = require("awful")
local wibox  = require("wibox")

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

    test_client("merged_titlebar")
    local c = async.wait_for_client("merged_titlebar", 5)
    assert(c, "client did not appear")

    c.floating = false
    c.border_width = 4
    async.sleep(0.05)
    assert(not c.floating, "client should be tiled")

    -- An expressible titlebar: align.horizontal is a :layout_node container, so
    -- its whole tree is a node in the merged solve.
    local title = wibox.widget.textbox("X")
    local tb = awful.titlebar(c, { size = 20, position = "top" })
    tb:set_widget(wibox.layout.align.horizontal(title, nil, nil))
    local root = tb:get_widget()
    assert(root, "titlebar should have a root widget")

    -- (1) Identity: the accessor is side-effect-free and returns this drawable.
    assert(awful.titlebar.get_existing(c, "top") == tb,
        "get_existing should return the client's titlebar drawable")
    assert(awful.titlebar.get_existing(c, "top"):get_widget() == root,
        "get_existing drawable's widget should be the root we set")

    -- Wait until the merged solve records the titlebar root in the placements map
    -- (the drawable needs a first draw + geometry before client_body_subtree folds
    -- it; until then it stays box-only and paints via the forest).
    local ok = async.wait_for_condition(function()
        awful.layout.arrange(s)
        return s._clay_widget_placements and s._clay_widget_placements[root] ~= nil
    end, 5)
    assert(ok, "titlebar root never reached the merged placements map")

    -- (6) The solve must never lazily create a titlebar that was not requested.
    assert(awful.titlebar.get_existing(c, "bottom") == nil,
        "merged solve must not create a bottom titlebar")
    assert(not c._request_titlebars_called,
        "merged solve must not trigger request::titlebars")

    -- (3) Snapshot the surface box + titlebar thickness before a content reflow.
    local before = _somewm_clay.client_frame_geometry(c)
    local bw = c.border_width or 0
    assert(before.surface.x == bw and before.surface.y == bw + 20, string.format(
        "[TEST] surface offset = %d,%d, expected %d,%d",
        before.surface.x, before.surface.y, bw, bw + 20))

    -- (2) A titlebar content relayout: drives a merged solve, fires zero wibox
    -- solves, and the box still comes from the merged solve (decoration == 0).
    _somewm_clay.reset_solve_counts()
    title:set_text("a considerably longer titlebar label")

    local cnt
    async.wait_for_condition(function()
        cnt = _somewm_clay.get_solve_counts()
        return cnt.merged >= 1
    end, 3)
    async.sleep(0.1) -- let the redraw that consumes the boxes settle
    cnt = _somewm_clay.get_solve_counts()
    io.stderr:write(string.format(
        "[TEST] after titlebar relayout: merged=%d wibox=%d decoration=%d total=%d\n",
        cnt.merged, cnt.wibox, cnt.decoration, cnt.total))
    assert(cnt.merged >= 1,
        "a titlebar content relayout should drive a merged screen solve")
    assert(cnt.wibox == 0, string.format(
        "titlebar content should paint from the merged solve, not the per-titlebar "
        .. "wibox forest (wibox=%d)", cnt.wibox))
    assert(cnt.decoration == 0, string.format(
        "titlebar box should come from the merged solve, not the per-client "
        .. "fallback (decoration=%d)", cnt.decoration))

    -- (3) Surface box and titlebar thickness unchanged by the content reflow.
    local after = _somewm_clay.client_frame_geometry(c)
    assert(after.surface.x == before.surface.x and after.surface.y == before.surface.y,
        string.format("surface must not move on titlebar content reflow: %d,%d -> %d,%d",
            before.surface.x, before.surface.y, after.surface.x, after.surface.y))
    assert(after.titlebar[1].size == 20,
        "titlebar thickness must stay 20 through a content reflow")

    -- (4) The placements-derived matrices are correct: a point inside the title
    -- (left slot, near the left edge) hit-tests to the title textbox.
    local found = tb:find_widgets(2, 10)
    local hit
    for _, e in ipairs(found) do
        if e.widget == title then hit = e end
    end
    assert(hit, "title textbox should be hit-testable from the merged solve")
    assert(hit.width > 0 and hit.height > 0,
        "hit-tested title should have a non-empty box")
    io.stderr:write(string.format(
        "[TEST] PASS: title hit-tests at x=%d w=%d h=%d\n",
        hit.x, hit.width, hit.height))

    -- (5) Fullscreen hides the titlebar (client_frame_sizes reports 0, so no
    -- widget node is built and the scene buffer is disabled), no crash.
    c.fullscreen = true
    async.sleep(0.1)
    awful.layout.arrange(s)
    async.sleep(0.1)
    local dgf = _somewm_clay.client_frame_geometry(c)
    assert(not dgf.titlebar[1].enabled,
        "fullscreen titlebar should be hidden (scene buffer disabled)")
    c.fullscreen = false
    async.sleep(0.1)

    io.stderr:write("[TEST] PASS: titlebar content folded into the merged solve\n")

    if c.valid then c:kill() end
    for _, pid in ipairs(test_client.get_spawned_pids()) do
        os.execute("kill -9 " .. pid .. " 2>/dev/null")
    end
    assert(async.wait_for_no_clients(5), "client did not close")
    runner.done()
end)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
