---------------------------------------------------------------------------
--- Test: somewm.layout declarative composition API.
---
--- Exercises layout.solve directly against synthetic widget trees so the
--- API surface (row/column/widget/spacer/percent/solve) is verified
--- independent of any downstream caller.
---
--- Coverage:
---   * widget mode placements (no screen)
---   * sizing: fit (default), grow, fixed, percent
---   * gap between siblings
---   * padding shorthands: number, {v,h}, {t,r,b,l}
---   * grow_max cap
---   * nested containers
---
--- Run: make test-one TEST=tests/test-somewm-layout.lua
---------------------------------------------------------------------------

local runner  = require("_runner")
local layout  = require("somewm.layout")
local helpers = require("_layout_helpers")

assert(_somewm_clay,
    "_somewm_clay must be available; this test exercises the layout engine")

local stub_widget = helpers.stub_widget
local find        = helpers.find_placement
local expect      = helpers.expect_placement

runner.run_steps({
    function()
        -- TEST 1: row of three grow widgets fills 300x100 evenly.
        io.stderr:write("[TEST 1] row, 3 grow widgets in 300x100\n")
        local a, b, c = stub_widget(0, 0), stub_widget(0, 0), stub_widget(0, 0)
        local r = layout.solve {
            width = 300, height = 100,
            root = layout.row {
                layout.widget(a, { grow = true }),
                layout.widget(b, { grow = true }),
                layout.widget(c, { grow = true }),
            },
        }
        assert(#r.placements == 3,
            string.format("[TEST 1] expected 3 placements, got %d", #r.placements))
        expect("TEST 1 a", find(r.placements, a), { x = 0,   y = 0, w = 100, h = 100 })
        expect("TEST 1 b", find(r.placements, b), { x = 100, y = 0, w = 100, h = 100 })
        expect("TEST 1 c", find(r.placements, c), { x = 200, y = 0, w = 100, h = 100 })
        io.stderr:write("[TEST 1] PASS\n")

        -- TEST 2: column with mixed sizing: fixed + grow + fixed.
        io.stderr:write("[TEST 2] column, fixed + grow + fixed in 100x300\n")
        local top, mid, bot = stub_widget(0, 0), stub_widget(0, 0), stub_widget(0, 0)
        local r2 = layout.solve {
            width = 100, height = 300,
            root = layout.column {
                layout.widget(top, { height = 50 }),
                layout.widget(mid, { grow = true }),
                layout.widget(bot, { height = 30 }),
            },
        }
        expect("TEST 2 top", find(r2.placements, top), { x = 0, y = 0,   w = 100, h = 50 })
        expect("TEST 2 mid", find(r2.placements, mid), { x = 0, y = 50,  w = 100, h = 220 })
        expect("TEST 2 bot", find(r2.placements, bot), { x = 0, y = 270, w = 100, h = 30 })
        io.stderr:write("[TEST 2] PASS\n")

        -- TEST 3: percent sizing on a child. Use 50% so the percent value
        -- is exactly representable in float (0.6f introduces 1px floor slop).
        io.stderr:write("[TEST 3] row, 50% master + grow stack in 200x100\n")
        local master = stub_widget(0, 0)
        local stack  = stub_widget(0, 0)
        local r3 = layout.solve {
            width = 200, height = 100,
            root = layout.row {
                layout.widget(master, { width = layout.percent(0.5) }),
                layout.widget(stack,  { grow = true }),
            },
        }
        expect("TEST 3 master", find(r3.placements, master),
            { x = 0,   y = 0, w = 100, h = 100 })
        expect("TEST 3 stack", find(r3.placements, stack),
            { x = 100, y = 0, w = 100, h = 100 })
        io.stderr:write("[TEST 3] PASS\n")

        -- TEST 4: gap between siblings.
        io.stderr:write("[TEST 4] row gap=10 between three grow widgets\n")
        local x, y, z = stub_widget(0, 0), stub_widget(0, 0), stub_widget(0, 0)
        local r4 = layout.solve {
            width = 320, height = 100,  -- 320 = 100*3 + 10*2
            root = layout.row {
                gap = 10,
                layout.widget(x, { grow = true }),
                layout.widget(y, { grow = true }),
                layout.widget(z, { grow = true }),
            },
        }
        expect("TEST 4 x", find(r4.placements, x), { x = 0,   y = 0, w = 100, h = 100 })
        expect("TEST 4 y", find(r4.placements, y), { x = 110, y = 0, w = 100, h = 100 })
        expect("TEST 4 z", find(r4.placements, z), { x = 220, y = 0, w = 100, h = 100 })
        io.stderr:write("[TEST 4] PASS\n")

        -- TEST 5: padding number shorthand (uniform).
        io.stderr:write("[TEST 5] padding=5 uniform around a single grow widget\n")
        local p1 = stub_widget(0, 0)
        local r5 = layout.solve {
            width = 100, height = 60,
            root = layout.row {
                padding = 5,
                layout.widget(p1, { grow = true }),
            },
        }
        expect("TEST 5 p1", find(r5.placements, p1), { x = 5, y = 5, w = 90, h = 50 })
        io.stderr:write("[TEST 5] PASS\n")

        -- TEST 6: padding {v,h} shorthand.
        io.stderr:write("[TEST 6] padding={4,8} (vertical, horizontal)\n")
        local p2 = stub_widget(0, 0)
        local r6 = layout.solve {
            width = 100, height = 60,
            root = layout.row {
                padding = { 4, 8 },  -- v=4 (top+bottom), h=8 (right+left)
                layout.widget(p2, { grow = true }),
            },
        }
        expect("TEST 6 p2", find(r6.placements, p2), { x = 8, y = 4, w = 84, h = 52 })
        io.stderr:write("[TEST 6] PASS\n")

        -- TEST 7: padding {t,r,b,l} full form.
        io.stderr:write("[TEST 7] padding={2,4,6,8} (t,r,b,l)\n")
        local p3 = stub_widget(0, 0)
        local r7 = layout.solve {
            width = 100, height = 60,
            root = layout.row {
                padding = { 2, 4, 6, 8 },
                layout.widget(p3, { grow = true }),
            },
        }
        expect("TEST 7 p3", find(r7.placements, p3), { x = 8, y = 2, w = 88, h = 52 })
        io.stderr:write("[TEST 7] PASS\n")

        -- TEST 8: layout.widgets convenience flattens into parent.
        io.stderr:write("[TEST 8] layout.widgets list inside row\n")
        local w1, w2 = stub_widget(0, 0), stub_widget(0, 0)
        local r8 = layout.solve {
            width = 200, height = 50,
            root = layout.row {
                layout.widgets({ w1, w2 }, { grow = true }),
            },
        }
        assert(#r8.placements == 2,
            string.format("[TEST 8] expected 2 placements, got %d", #r8.placements))
        expect("TEST 8 w1", find(r8.placements, w1), { x = 0,   y = 0, w = 100, h = 50 })
        expect("TEST 8 w2", find(r8.placements, w2), { x = 100, y = 0, w = 100, h = 50 })
        io.stderr:write("[TEST 8] PASS\n")

        -- TEST 9: nested container.
        io.stderr:write("[TEST 9] row containing column\n")
        local outer = stub_widget(0, 0)
        local inner1, inner2 = stub_widget(0, 0), stub_widget(0, 0)
        local r9 = layout.solve {
            width = 200, height = 100,
            root = layout.row {
                layout.widget(outer, { width = 50 }),
                layout.column {
                    grow = true,
                    layout.widget(inner1, { grow = true }),
                    layout.widget(inner2, { grow = true }),
                },
            },
        }
        expect("TEST 9 outer", find(r9.placements, outer),
            { x = 0,  y = 0,  w = 50,  h = 100 })
        expect("TEST 9 inner1", find(r9.placements, inner1),
            { x = 50, y = 0,  w = 150, h = 50 })
        expect("TEST 9 inner2", find(r9.placements, inner2),
            { x = 50, y = 50, w = 150, h = 50 })
        io.stderr:write("[TEST 9] PASS\n")

        -- TEST 10: grow_max caps a grow child.
        io.stderr:write("[TEST 10] grow_max=80 caps a grow child in 200 width\n")
        local capped = stub_widget(0, 0)
        local rest   = stub_widget(0, 0)
        local r10 = layout.solve {
            width = 200, height = 50,
            root = layout.row {
                layout.widget(capped, { grow = true, grow_max = 80 }),
                layout.widget(rest,   { grow = true }),
            },
        }
        local pcap = find(r10.placements, capped)
        assert(pcap.width == 80,
            string.format("[TEST 10] capped width: expected 80, got %d", pcap.width))
        local prest = find(r10.placements, rest)
        assert(prest.width == 120,
            string.format("[TEST 10] rest width: expected 120, got %d", prest.width))
        io.stderr:write("[TEST 10] PASS\n")

        -- TEST 11: solve.root must be a container.
        io.stderr:write("[TEST 11] solve rejects non-container root\n")
        local leaf_widget = stub_widget(0, 0)
        local ok, err = pcall(layout.solve, {
            width = 100, height = 100,
            root = layout.widget(leaf_widget),
        })
        assert(not ok, "[TEST 11] solve should error on leaf root")
        assert(err:find("must be a container", 1, true),
            string.format("[TEST 11] expected error about container; got: %s", err))
        io.stderr:write("[TEST 11] PASS\n")

        -- TEST 12: layout.percent sentinel is recognized.
        io.stderr:write("[TEST 12] layout.percent identity\n")
        local pct = layout.percent(0.75)
        assert(type(pct) == "table", "[TEST 12] percent returns a table")
        assert(pct._percent == 0.75, "[TEST 12] _percent stores the value")
        io.stderr:write("[TEST 12] PASS\n")

        -- TEST 13: align right-bottom places a fixed child in the corner.
        io.stderr:write("[TEST 13] align={x=right,y=bottom} pushes child to corner\n")
        local corner = stub_widget(0, 0)
        local r13 = layout.solve {
            width = 200, height = 100,
            root = layout.row {
                align = { x = "right", y = "bottom" },
                layout.widget(corner, { width = 50, height = 30 }),
            },
        }
        expect("TEST 13 corner", find(r13.placements, corner),
            { x = 150, y = 70, w = 50, h = 30 })
        io.stderr:write("[TEST 13] PASS\n")

        -- TEST 14: align center centers a fixed child on both axes.
        io.stderr:write("[TEST 14] align={x=center,y=center} centers a fixed child\n")
        local centered = stub_widget(0, 0)
        local r14 = layout.solve {
            width = 200, height = 100,
            root = layout.row {
                align = { x = "center", y = "center" },
                layout.widget(centered, { width = 60, height = 20 }),
            },
        }
        expect("TEST 14 centered", find(r14.placements, centered),
            { x = 70, y = 40, w = 60, h = 20 })
        io.stderr:write("[TEST 14] PASS\n")

        -- TEST 15: alignment is a no-op on an axis where the child fills it
        -- via PERCENT(100). This matters because PERCENT children take a
        -- different code path in Clay than GROW children; the no-op behavior
        -- is purely arithmetic (extraSpace = 0), not a Clay short-circuit.
        io.stderr:write("[TEST 15] align right + width=100% is a no-op on x\n")
        local filled = stub_widget(0, 0)
        local r15 = layout.solve {
            width = 200, height = 100,
            root = layout.row {
                align = { x = "right", y = "center" },
                layout.widget(filled, {
                    width = layout.percent(1),
                    height = 40,
                }),
            },
        }
        expect("TEST 15 filled", find(r15.placements, filled),
            { x = 0, y = 30, w = 200, h = 40 })
        io.stderr:write("[TEST 15] PASS\n")

        -- TEST 16: layout.subtree pass-through accepts a container directly.
        io.stderr:write("[TEST 16] subtree pass-through on a container\n")
        local container = layout.row { layout.widget(stub_widget(0, 0)) }
        local resolved = layout.subtree(container, { bounds = { width = 100, height = 100 } })
        assert(resolved == container,
            "[TEST 16] subtree should return the container unchanged when passed one directly")
        io.stderr:write("[TEST 16] PASS\n")

        -- TEST 18: layout.subtree errors on non-container input.
        io.stderr:write("[TEST 18] subtree rejects non-container input\n")
        local ok = pcall(layout.subtree, "not a container", {})
        assert(not ok, "[TEST 18] subtree should error on a string")
        ok = pcall(layout.subtree, { _type = "widget" }, {})
        assert(not ok, "[TEST 18] subtree should error on a non-container node")
        io.stderr:write("[TEST 18] PASS\n")

        -- TEST 19: layout.descriptor packages a spec into pure data.
        io.stderr:write("[TEST 19] descriptor wraps spec fields\n")
        local body_fn = function(_) end
        local skip = function(_, _) return false end
        local d = layout.descriptor {
            name     = "test.layout",
            body     = body_fn,
            skip_gap = skip,
            no_gap   = true,
        }
        assert(d._type == "layout_descriptor", "[TEST 19] _type should be layout_descriptor")
        assert(d.name == "test.layout", "[TEST 19] name should be carried through")
        assert(d.body == body_fn, "[TEST 19] body should be carried through")
        assert(d.skip_gap == skip, "[TEST 19] skip_gap should be carried through")
        assert(d.no_gap == true, "[TEST 19] no_gap should be carried through")
        io.stderr:write("[TEST 19] PASS\n")

        -- TEST 20: descriptor accepts positional [1] tree shorthand.
        io.stderr:write("[TEST 20] descriptor accepts positional tree\n")
        local static_tree = layout.row { layout.widget(stub_widget(0, 0)) }
        local d2 = layout.descriptor {
            name = "test.static",
            static_tree,
        }
        assert(d2.tree == static_tree, "[TEST 20] positional tree should land in .tree")
        assert(d2.body == nil, "[TEST 20] body should be nil for positional-only spec")
        io.stderr:write("[TEST 20] PASS\n")

        io.stderr:write("[ALL TESTS] PASS\n")
        return true
    end,
}, { kill_clients = false })

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
