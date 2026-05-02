---------------------------------------------------------------------------
--- Test: Phase 8 wibox.container.* Clay-backed pixel positions.
---
--- Verifies that wibox.container.margin / .place / .background produce the
--- expected placements through the Clay fast path under a live compositor
--- (where _somewm_clay is wired). The legacy fallback path is covered by the
--- existing busted specs in spec/wibox/container/*_spec.lua, which run with
--- _somewm_clay = nil and exercise the same code below the gate.
---
--- Coverage:
---   * margin uniform / asymmetric
---   * place center / corner / content_fill_horizontal no-op
---   * background border_strategy "inner" and "none"
---   * tile inherits from place transparently (smoke)
---
--- Run: make test-one TEST=tests/test-container-layout.lua
---------------------------------------------------------------------------

local runner  = require("_runner")
local wibox   = require("wibox")
local helpers = require("_layout_helpers")

assert(_somewm_clay,
    "_somewm_clay must be available; this test exercises the Clay path")

local stub_widget = helpers.stub_widget
local expect      = helpers.expect_placement

runner.run_steps({
    function()
        -- TEST 1: margin uniform 10px on all sides.
        io.stderr:write("[TEST 1] margin uniform=10 in 100x60\n")
        local inner = stub_widget(0, 0)
        local m = wibox.container.margin(inner, 10, 10, 10, 10)
        local pls = m:layout({"test"}, 100, 60)
        assert(#pls == 1,
            string.format("[TEST 1] expected 1 placement, got %d", #pls))
        expect("TEST 1 inner", pls[1], { x = 10, y = 10, w = 80, h = 40 })
        io.stderr:write("[TEST 1] PASS\n")

        -- TEST 2: margin asymmetric (left=2, right=4, top=6, bottom=8).
        io.stderr:write("[TEST 2] margin l=2 r=4 t=6 b=8 in 100x60\n")
        local inner2 = stub_widget(0, 0)
        local m2 = wibox.container.margin(inner2, 2, 4, 6, 8)
        local pls2 = m2:layout({"test"}, 100, 60)
        expect("TEST 2 inner", pls2[1], { x = 2, y = 6, w = 94, h = 46 })
        io.stderr:write("[TEST 2] PASS\n")

        -- TEST 3: place center/center with a fixed-fit child.
        io.stderr:write("[TEST 3] place center, fit child 50x30 in 200x100\n")
        local centered = stub_widget(50, 30)
        local pc = wibox.container.place(centered, "center", "center")
        local pls3 = pc:layout({"test"}, 200, 100)
        expect("TEST 3 centered", pls3[1], { x = 75, y = 35, w = 50, h = 30 })
        io.stderr:write("[TEST 3] PASS\n")

        -- TEST 4: place top-left.
        io.stderr:write("[TEST 4] place left/top, fit child 40x20 in 100x100\n")
        local tl = stub_widget(40, 20)
        local p_tl = wibox.container.place(tl, "left", "top")
        local pls4 = p_tl:layout({"test"}, 100, 100)
        expect("TEST 4 top-left", pls4[1], { x = 0, y = 0, w = 40, h = 20 })
        io.stderr:write("[TEST 4] PASS\n")

        -- TEST 5: place bottom-right.
        io.stderr:write("[TEST 5] place right/bottom, fit child 40x20 in 100x100\n")
        local br = stub_widget(40, 20)
        local p_br = wibox.container.place(br, "right", "bottom")
        local pls5 = p_br:layout({"test"}, 100, 100)
        expect("TEST 5 bottom-right", pls5[1], { x = 60, y = 80, w = 40, h = 20 })
        io.stderr:write("[TEST 5] PASS\n")

        -- TEST 6: place with content_fill_horizontal stretches the child;
        -- alignment becomes a no-op on x. PERCENT child path (not GROW) — the
        -- gate for the "alignment-with-PERCENT-child" arithmetic case.
        io.stderr:write("[TEST 6] place right/center + content_fill_horizontal\n")
        local fill = stub_widget(40, 20)
        local p_fill = wibox.container.place(fill, "right", "center")
        p_fill:set_content_fill_horizontal(true)
        local pls6 = p_fill:layout({"test"}, 200, 100)
        expect("TEST 6 fill", pls6[1], { x = 0, y = 40, w = 200, h = 20 })
        io.stderr:write("[TEST 6] PASS\n")

        -- TEST 7: background border_strategy="inner", border_width=4.
        io.stderr:write("[TEST 7] background inner border bw=4 in 100x60\n")
        local bg_inner = stub_widget(0, 0)
        local bg = wibox.container.background(bg_inner)
        bg:set_border_width(4)
        bg:set_border_strategy("inner")
        local pls7 = bg:layout({"test"}, 100, 60)
        expect("TEST 7 inner", pls7[1], { x = 4, y = 4, w = 92, h = 52 })
        io.stderr:write("[TEST 7] PASS\n")

        -- TEST 8: background border_strategy="none" → no inset even with bw set.
        io.stderr:write("[TEST 8] background border_strategy=none in 100x60\n")
        local bg2_inner = stub_widget(0, 0)
        local bg2 = wibox.container.background(bg2_inner)
        bg2:set_border_width(4)
        bg2:set_border_strategy("none")
        local pls8 = bg2:layout({"test"}, 100, 60)
        expect("TEST 8 none", pls8[1], { x = 0, y = 0, w = 100, h = 60 })
        io.stderr:write("[TEST 8] PASS\n")

        -- TEST 9: tile inherits from place transparently. tile's own
        -- constructor has a pre-existing colon-call mismatch (tile.lua:220
        -- vs. tile.lua:162) that drops the args table, so we build the tile
        -- via its module table and configure it directly. This still proves
        -- that tile instances delegate :layout to place:layout — the goal
        -- here.
        io.stderr:write("[TEST 9] tile instance, place:layout drives center\n")
        local tinner = stub_widget(30, 20)
        local t = wibox.container.tile()
        t:set_widget(tinner)
        t:set_halign("center")
        t:set_valign("center")
        local pls9 = t:layout({"test"}, 100, 60)
        assert(pls9 and #pls9 == 1,
            string.format("[TEST 9] expected 1 placement, got %s",
                pls9 and #pls9 or "nil"))
        expect("TEST 9 tile-center", pls9[1], { x = 35, y = 20, w = 30, h = 20 })
        io.stderr:write("[TEST 9] PASS\n")

        io.stderr:write("[ALL TESTS] PASS\n")
        return true
    end,
}, { kill_clients = false })

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
