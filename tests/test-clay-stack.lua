---------------------------------------------------------------------------
--- Test: layout.stack -- children attach to parent as floating elements.
---
--- Two modes:
---   1. Overlap mode (no x/y/w/h on children) -- every child fills the
---      parent rect. This is what `clay.max` needs to express "all
---      clients occupy the workarea, only the topmost is visible."
---   2. Absolute mode (explicit { x, y, width, height } on children) --
---      each child sits at the given parent-relative coords with the
---      given size. This is what `wibox.layout.{stack, manual, grid}`
---      and `clay.floating` need.
---------------------------------------------------------------------------

local runner = require("_runner")
local layout = require("somewm.layout")

-- Substitute a placeholder for the widget ref. Widget mode stores the
-- ref and returns it in placements; we just need something distinct
-- per child so we can match results back to inputs.
local function widget_token(label)
    return { _label = label }
end

local function find_placement(placements, token)
    for _, p in ipairs(placements) do
        if p.widget == token then return p end
    end
    return nil
end

local function near(actual, expected, label)
    local tol = 1
    assert(math.abs(actual - expected) <= tol,
        string.format("%s: got %d, expected %d", label, actual, expected))
end

local steps = {
    -- Overlap mode: all children fill the parent rect.
    function()
        local a, b, c = widget_token("a"), widget_token("b"), widget_token("c")
        local result = layout.solve {
            width  = 800,
            height = 600,
            source = "wibox",
            root = layout.stack {
                layout.widget(a),
                layout.widget(b),
                layout.widget(c),
            },
        }

        for _, token in ipairs({ a, b, c }) do
            local p = find_placement(result.placements, token)
            assert(p, "stack overlap: child placement missing for "
                .. tostring(token._label))
            near(p.x, 0, "overlap " .. token._label .. " x")
            near(p.y, 0, "overlap " .. token._label .. " y")
            near(p.width, 800, "overlap " .. token._label .. " width")
            near(p.height, 600, "overlap " .. token._label .. " height")
        end
        io.stderr:write("[TEST] PASS: stack overlap fills parent for all children\n")
        return true
    end,

    -- Absolute mode: each child at its specified coords + size.
    function()
        local a, b = widget_token("a"), widget_token("b")
        local result = layout.solve {
            width  = 800,
            height = 600,
            source = "wibox",
            root = layout.stack {
                layout.widget(a, { x = 10,  y = 20,  width = 100, height = 50 }),
                layout.widget(b, { x = 200, y = 100, width = 80,  height = 40 }),
            },
        }

        local pa = find_placement(result.placements, a)
        assert(pa, "absolute: placement a missing")
        near(pa.x, 10,  "abs a x")
        near(pa.y, 20,  "abs a y")
        near(pa.width,  100, "abs a width")
        near(pa.height, 50,  "abs a height")

        local pb = find_placement(result.placements, b)
        assert(pb, "absolute: placement b missing")
        near(pb.x, 200, "abs b x")
        near(pb.y, 100, "abs b y")
        near(pb.width,  80,  "abs b width")
        near(pb.height, 40,  "abs b height")
        io.stderr:write("[TEST] PASS: stack absolute positions children at given coords\n")
        return true
    end,

    -- Mixed: stack inside a row. The row has two children -- a fixed
    -- 200px column and a stack that grows. Verify the stack's children
    -- inherit the stack's rect, not the row's.
    function()
        local a, b = widget_token("a"), widget_token("b")
        local result = layout.solve {
            width  = 800,
            height = 600,
            source = "wibox",
            root = layout.row {
                layout.widget(widget_token("sidebar"), { width = 200 }),
                layout.stack {
                    grow = true,
                    layout.widget(a),
                    layout.widget(b, { x = 50, y = 50, width = 100, height = 100 }),
                },
            },
        }

        local pa = find_placement(result.placements, a)
        assert(pa, "mixed: overlap child a missing")
        near(pa.x, 200, "mixed a x")  -- stack starts at sidebar end
        near(pa.y, 0,   "mixed a y")
        near(pa.width,  600, "mixed a width")  -- stack width 800-200
        near(pa.height, 600, "mixed a height")

        local pb = find_placement(result.placements, b)
        assert(pb, "mixed: absolute child b missing")
        near(pb.x, 250, "mixed b x")  -- stack origin (200) + offset (50)
        near(pb.y, 50,  "mixed b y")
        near(pb.width,  100, "mixed b width")
        near(pb.height, 100, "mixed b height")
        io.stderr:write("[TEST] PASS: nested stack inherits its own parent rect\n")
        return true
    end,

    -- Sanity: row containers (non-stack) ignore x/y on children. A
    -- regression here would mean the floating config leaked into
    -- normal flow.
    function()
        local a, b = widget_token("a"), widget_token("b")
        local result = layout.solve {
            width  = 800,
            height = 600,
            source = "wibox",
            root = layout.row {
                layout.widget(a, { x = 999, y = 999, width = 100 }),
                layout.widget(b, { width = 100 }),
            },
        }

        local pa = find_placement(result.placements, a)
        assert(pa, "row sanity: placement a missing")
        -- a should be at row origin, not at (999, 999). The row flowed
        -- it normally because it's not a stack.
        near(pa.x, 0, "row a x (should ignore stack-only x prop)")
        near(pa.y, 0, "row a y (should ignore stack-only y prop)")
        io.stderr:write("[TEST] PASS: non-stack containers ignore x/y props\n")
        return true
    end,

    function()
        io.stderr:write("Test finished successfully.\n")
        awesome.quit()
        return true
    end,
}

runner.run_steps(steps, { kill_clients = false })

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
