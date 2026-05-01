---------------------------------------------------------------------------
--- Test: somewm.placement anchor solver.
---
--- Exercises somewm.placement.solve directly: parent rect + target size +
--- anchor name -> {x, y, width, height} in absolute coords. The same call
--- shape that awful.placement.align uses on its Clay fast path.
---
--- Coverage:
---   * 9 full-axis anchors at origin parent
---   * Same 9 anchors at offset parent (multi-screen smoke)
---   * Custom anchor table {x, y} bypasses string lookup
---   * Unknown / partial-axis anchor returns nil (caller falls back)
---   * Target larger than parent (overflow): Clay clips - documented divergence
---
--- Run: make test-one TEST=tests/test-somewm-placement.lua
---------------------------------------------------------------------------

local runner    = require("_runner")
local placement = require("somewm.placement")

assert(_somewm_clay,
    "_somewm_clay must be available; this test exercises the Clay path")

local function expect(label, geo, ex)
    assert(geo, string.format("[%s] expected geometry, got nil", label))
    assert(geo.x == ex.x,
        string.format("[%s] x: expected %d, got %s", label, ex.x, tostring(geo.x)))
    assert(geo.y == ex.y,
        string.format("[%s] y: expected %d, got %s", label, ex.y, tostring(geo.y)))
    assert(geo.width == ex.w,
        string.format("[%s] w: expected %d, got %s", label, ex.w, tostring(geo.width)))
    assert(geo.height == ex.h,
        string.format("[%s] h: expected %d, got %s", label, ex.h, tostring(geo.height)))
end

runner.run_steps({
    function()
        -- TEST 1: 9 anchors in 800x600 parent at origin, 100x80 target.
        -- Expected coords for each anchor:
        --   top_left   (0,   0)    top    (350, 0)    top_right    (700, 0)
        --   left       (0,   260)  centered(350,260)  right        (700, 260)
        --   bottom_left(0,   520)  bottom (350, 520)  bottom_right (700, 520)
        io.stderr:write("[TEST 1] 9 anchors in 800x600 parent at origin\n")
        local parent = { x = 0, y = 0, width = 800, height = 600 }
        local cases = {
            { anchor = "top_left",     x = 0,   y = 0   },
            { anchor = "top",          x = 350, y = 0   },
            { anchor = "top_right",    x = 700, y = 0   },
            { anchor = "left",         x = 0,   y = 260 },
            { anchor = "centered",     x = 350, y = 260 },
            { anchor = "right",        x = 700, y = 260 },
            { anchor = "bottom_left",  x = 0,   y = 520 },
            { anchor = "bottom",       x = 350, y = 520 },
            { anchor = "bottom_right", x = 700, y = 520 },
        }
        for _, c in ipairs(cases) do
            local r = placement.solve {
                parent = parent, target_width = 100, target_height = 80,
                anchor = c.anchor,
            }
            expect("TEST 1 " .. c.anchor, r, { x = c.x, y = c.y, w = 100, h = 80 })
        end
        io.stderr:write("[TEST 1] PASS\n")

        -- TEST 2: same 9 anchors with parent offset to (1920, 0).
        -- Confirms offset_x/offset_y propagate through layout.solve into the
        -- workarea bounds in absolute coords.
        io.stderr:write("[TEST 2] 9 anchors in 800x600 parent at (1920, 0)\n")
        local parent2 = { x = 1920, y = 0, width = 800, height = 600 }
        for _, c in ipairs(cases) do
            local r = placement.solve {
                parent = parent2, target_width = 100, target_height = 80,
                anchor = c.anchor,
            }
            expect("TEST 2 " .. c.anchor, r,
                { x = c.x + 1920, y = c.y, w = 100, h = 80 })
        end
        io.stderr:write("[TEST 2] PASS\n")

        -- TEST 3: custom anchor table {x, y} bypasses string-name lookup.
        io.stderr:write("[TEST 3] custom anchor {x=right, y=bottom}\n")
        local r3 = placement.solve {
            parent = parent, target_width = 50, target_height = 30,
            anchor = { x = "right", y = "bottom" },
        }
        expect("TEST 3", r3, { x = 750, y = 570, w = 50, h = 30 })
        io.stderr:write("[TEST 3] PASS\n")

        -- TEST 4: partial-axis or unknown anchor returns nil so the awful
        -- caller can fall back to the legacy align_map. center_vertical
        -- and center_horizontal are intentionally not in anchor_to_align.
        io.stderr:write("[TEST 4] partial-axis / unknown returns nil\n")
        assert(placement.solve {
            parent = parent, target_width = 50, target_height = 30,
            anchor = "center_vertical",
        } == nil, "[TEST 4] center_vertical should return nil")
        assert(placement.solve {
            parent = parent, target_width = 50, target_height = 30,
            anchor = "center_horizontal",
        } == nil, "[TEST 4] center_horizontal should return nil")
        assert(placement.solve {
            parent = parent, target_width = 50, target_height = 30,
            anchor = "bogus_anchor_name",
        } == nil, "[TEST 4] unknown anchor should return nil")
        io.stderr:write("[TEST 4] PASS\n")

        -- TEST 5: target larger than parent. Clay preserves the requested
        -- SIZE (does not clip width/height to parent) but clamps any
        -- negative anchor offset to 0 - so `centered` overflow lands at
        -- (0, 0) under Clay, while legacy align_map produces (-100, -100)
        -- for an 800x600 parent with a 1000x800 child. This is a known
        -- divergence; no real-world placement caller hands in oversize
        -- targets, but the test pins the contract so future Clay updates
        -- that change overflow behavior get caught.
        io.stderr:write("[TEST 5] target larger than parent (overflow)\n")
        local r5 = placement.solve {
            parent = parent, target_width = 1000, target_height = 800,
            anchor = "top_left",
        }
        assert(r5.width == 1000 and r5.height == 800,
            string.format("[TEST 5] size preserved: expected 1000x800, got %dx%d",
                r5.width, r5.height))
        assert(r5.x == 0 and r5.y == 0,
            string.format("[TEST 5] top_left overflow at origin: got (%d, %d)",
                r5.x, r5.y))
        io.stderr:write("[TEST 5] PASS\n")

        io.stderr:write("[ALL TESTS] PASS\n")
        return true
    end
}, { kill_clients = false })

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
