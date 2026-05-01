---------------------------------------------------------------------------
--- Test: wibox.layout.align expand modes routed through Clay.
---
--- Phase 5 W3: align.expand="outside" moves from a legacy bespoke path
--- (third stuck to far edge with explicit subtraction math) to a Clay
--- descriptor (first/third grow equally, second takes fit-size in the
--- middle). expand="inside" was already Clay-routed; this test covers
--- both modes against a real Clay engine to confirm the migration
--- produces matching geometry.
---------------------------------------------------------------------------

local runner = require("_runner")
local test_client = require("_client")
local wibox = require("wibox")

if not test_client.is_available() then
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local function stub(w, h)
    return wibox.widget {
        widget = wibox.container.background,
        forced_width = w,
        forced_height = h,
    }
end

local function find(placements, widget)
    for _, p in ipairs(placements) do
        if p._widget == widget then return p end
    end
    return nil
end

local steps = {
    -- expand="inside": first/third take fit, second grows.
    function()
        local first  = stub(100, 10)
        local second = stub(100, 15)
        local third  = stub(100, 10)
        local layout = wibox.layout.align.vertical()
        layout:set_first(first)
        layout:set_second(second)
        layout:set_third(third)
        layout:set_expand("inside")

        local placements = layout:layout({}, 100, 100)
        local pf = find(placements, first)
        local ps = find(placements, second)
        local pt = find(placements, third)

        assert(pf and ps and pt, "all three widgets should be placed")
        assert(pf._height == 10,
            string.format("inside: first height %d != 10", pf._height))
        assert(pt._height == 10,
            string.format("inside: third height %d != 10", pt._height))
        -- Second grows to fill remaining: 100 - 10 - 10 = 80.
        assert(ps._height == 80,
            string.format("inside: second height %d != 80", ps._height))

        io.stderr:write("[TEST] PASS: align expand=inside via Clay\n")
        return true
    end,

    -- expand="outside": first/third grow, second takes fit-size centered.
    function()
        local first  = stub(100, 10)
        local second = stub(100, 15)
        local third  = stub(100, 10)
        local layout = wibox.layout.align.vertical()
        layout:set_first(first)
        layout:set_second(second)
        layout:set_third(third)
        layout:set_expand("outside")

        local placements = layout:layout({}, 100, 100)
        local pf = find(placements, first)
        local ps = find(placements, second)
        local pt = find(placements, third)

        assert(pf and ps and pt, "all three widgets should be placed")
        -- second takes its fit (15); first and third share remaining 85
        -- equally (42 + 43 with rounding).
        assert(ps._height == 15,
            string.format("outside: second height %d != 15", ps._height))
        assert(math.abs(pf._height - 42) <= 2,
            string.format("outside: first height %d not near 42", pf._height))
        assert(math.abs(pt._height - 42) <= 2,
            string.format("outside: third height %d not near 42", pt._height))

        io.stderr:write("[TEST] PASS: align expand=outside via Clay\n")
        return true
    end,

    -- expand="none": each widget at its fit size, anchored independently
    -- (first top, third bottom, second centered). Routed via layout.stack
    -- with absolute positions. Mirrors the busted spec's expected values.
    function()
        local first  = stub(100, 10)
        local second = stub(100, 15)
        local third  = stub(100, 10)
        local layout = wibox.layout.align.vertical()
        layout:set_first(first)
        layout:set_second(second)
        layout:set_third(third)
        layout:set_expand("none")

        local placements = layout:layout({}, 100, 100)
        local pf = find(placements, first)
        local ps = find(placements, second)
        local pt = find(placements, third)

        assert(pf and ps and pt, "all three widgets should be placed")
        -- first at (0, 0, 100, 10)
        assert(pf._matrix.x0 == 0 and pf._matrix.y0 == 0,
            string.format("none: first at (%d, %d) != (0, 0)",
                pf._matrix.x0, pf._matrix.y0))
        assert(pf._width == 100 and pf._height == 10,
            string.format("none: first %dx%d != 100x10",
                pf._width, pf._height))
        -- third at (0, 90, 100, 10)
        assert(pt._matrix.x0 == 0 and pt._matrix.y0 == 90,
            string.format("none: third at (%d, %d) != (0, 90)",
                pt._matrix.x0, pt._matrix.y0))
        assert(pt._width == 100 and pt._height == 10,
            string.format("none: third %dx%d != 100x10",
                pt._width, pt._height))
        -- second at (0, 42, 100, 15)
        assert(ps._matrix.x0 == 0 and ps._matrix.y0 == 42,
            string.format("none: second at (%d, %d) != (0, 42)",
                ps._matrix.x0, ps._matrix.y0))
        assert(ps._width == 100 and ps._height == 15,
            string.format("none: second %dx%d != 100x15",
                ps._width, ps._height))

        io.stderr:write("[TEST] PASS: align expand=none via Clay stack\n")
        return true
    end,
}

runner.run_steps(steps, { kill_clients = false })
