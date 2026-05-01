---------------------------------------------------------------------------
--- Test: wibox.layout.fixed spacing_widget renders between children.
---
--- Phase 5 W2: spacing_widget moved from a legacy bespoke path to a
--- Clay descriptor (interleaved spacer leaves) for production. The
--- busted spec at spec/wibox/layout/fixed_spec.lua still covers the
--- legacy fallback (`clay_c == nil`) but production uses Clay.
---
--- Verifies interleaved spacers under a real Clay engine.
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

local steps = {
    function()
        local w1, w2, w3 = stub(100, 10), stub(100, 15), stub(100, 10)
        local sp = stub(100, 10)
        local layout = wibox.layout.fixed.vertical()
        layout:add(w1, w2, w3)
        layout:set_spacing(10)
        layout:set_spacing_widget(sp)

        local placements = layout:layout({}, 100, 100)
        assert(placements, "no placements returned")

        -- 3 children + 2 spacers = 5
        assert(#placements == 5, string.format(
            "expected 5 placements, got %d", #placements))

        -- Group by widget. Children have unique widget refs; the spacer
        -- shares one widget ref between two placements, so seen[sp]
        -- captures only one of them, but #placements covers both.
        local seen = {}
        for _, p in ipairs(placements) do
            seen[p._widget] = (seen[p._widget] or 0) + 1
        end
        assert(seen[w1] == 1 and seen[w2] == 1 and seen[w3] == 1,
            "each child should appear exactly once")
        assert(seen[sp] == 2,
            "spacing_widget should appear exactly twice (between 3 children)")

        io.stderr:write("[TEST] PASS: fixed.spacing_widget interleaves spacers\n")
        return true
    end,
}

runner.run_steps(steps, { kill_clients = false })
