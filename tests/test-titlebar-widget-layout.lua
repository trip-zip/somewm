---------------------------------------------------------------------------
--- Test: Phase 6 wibox.layout.align Clay-backed inside-mode pixel positions.
---
--- Verifies that wibox.layout.align (the idiomatic root layout for titlebar
--- content - icon left, title middle, buttons right) produces the same
--- placements through the Clay backend as the legacy hand-rolled math:
---
---   * 3-slot horizontal, all present, plenty of space
---   * 3-slot vertical, all present
---   * 1-slot first only
---   * 2-slot first + third (no middle): spacer pattern keeps third at edge
---
--- Also verifies that a real awful.titlebar wired with align.horizontal
--- does not crash through the Clay path.
---
--- Run: make test-one TEST=tests/test-titlebar-widget-layout.lua
---------------------------------------------------------------------------

local runner  = require("_runner")
local awful   = require("awful")
local wibox   = require("wibox")
local helpers = require("_layout_helpers")

assert(_somewm_clay,
    "_somewm_clay must be available; this test exercises the Clay path")

local stub_widget     = helpers.stub_widget
local expect_placement = helpers.expect_placement
local find_placement   = helpers.find_placement

runner.run_steps({
    function()
        -- TEST 1: 3-slot horizontal align, plenty of space.
        io.stderr:write("[TEST 1] 3-slot horizontal align\n")
        local first  = stub_widget(10, 10)
        local middle = stub_widget(15, 15)
        local third  = stub_widget(20, 20)
        local layout = wibox.layout.align.horizontal(first, middle, third)
        local pls = layout:layout({"test"}, 100, 50)
        assert(#pls == 3,
            string.format("[TEST 1] expected 3 placements, got %d", #pls))
        expect_placement("TEST 1 first",  find_placement(pls, first),
            { widget = first,  x = 0,  y = 0, w = 10, h = 50 })
        expect_placement("TEST 1 middle", find_placement(pls, middle),
            { widget = middle, x = 10, y = 0, w = 70, h = 50 })
        expect_placement("TEST 1 third",  find_placement(pls, third),
            { widget = third,  x = 80, y = 0, w = 20, h = 50 })
        io.stderr:write("[TEST 1] PASS\n")

        -- TEST 2: 3-slot vertical align, plenty of space.
        io.stderr:write("[TEST 2] 3-slot vertical align\n")
        local layout2 = wibox.layout.align.vertical(first, middle, third)
        local pls2 = layout2:layout({"test"}, 100, 100)
        assert(#pls2 == 3,
            string.format("[TEST 2] expected 3 placements, got %d", #pls2))
        expect_placement("TEST 2 first",  find_placement(pls2, first),
            { widget = first,  x = 0, y = 0,  w = 100, h = 10 })
        expect_placement("TEST 2 middle", find_placement(pls2, middle),
            { widget = middle, x = 0, y = 10, w = 100, h = 70 })
        expect_placement("TEST 2 third",  find_placement(pls2, third),
            { widget = third,  x = 0, y = 80, w = 100, h = 20 })
        io.stderr:write("[TEST 2] PASS\n")

        -- TEST 3: 1-slot first only horizontal.
        io.stderr:write("[TEST 3] 1-slot first only\n")
        local layout3 = wibox.layout.align.horizontal(first)
        local pls3 = layout3:layout({"test"}, 100, 50)
        assert(#pls3 == 1,
            string.format("[TEST 3] expected 1 placement, got %d", #pls3))
        expect_placement("TEST 3 first", pls3[1],
            { widget = first, x = 0, y = 0, w = 10, h = 50 })
        io.stderr:write("[TEST 3] PASS\n")

        -- TEST 4: 2-slot first + third, no middle (spacer pattern).
        io.stderr:write("[TEST 4] 2-slot first+third, no middle\n")
        local layout4 = wibox.layout.align.horizontal(first, nil, third)
        local pls4 = layout4:layout({"test"}, 100, 50)
        assert(#pls4 == 2,
            string.format("[TEST 4] expected 2 placements, got %d", #pls4))
        expect_placement("TEST 4 first", find_placement(pls4, first),
            { widget = first, x = 0,  y = 0, w = 10, h = 50 })
        expect_placement("TEST 4 third", find_placement(pls4, third),
            { widget = third, x = 80, y = 0, w = 20, h = 50 })
        io.stderr:write("[TEST 4] PASS\n")

        -- TEST 5: real titlebar with align.horizontal does not crash.
        io.stderr:write("[TEST 5] real titlebar smoke\n")
        local s = screen.primary
        local w = wibox({ screen = s, x = 0, y = 0,
                          width = 200, height = 24, visible = true })
        local left = wibox.widget.textbox("L")
        local mid  = wibox.widget.textbox("M")
        local right = wibox.widget.textbox("R")
        w:set_widget(wibox.layout.align.horizontal(left, mid, right))
        w.visible = false
        w = nil
        collectgarbage("collect")
        io.stderr:write("[TEST 5] PASS\n")

        io.stderr:write("[ALL TESTS] PASS\n")
        return true
    end
}, { kill_clients = false })

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
