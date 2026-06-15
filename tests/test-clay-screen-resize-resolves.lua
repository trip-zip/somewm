---------------------------------------------------------------------------
--- Test: a pure output-size change re-solves the screen (Wiring).
---
--- fake_resize emits the screen's property::geometry; with no client to shift,
--- the origin-shift loop is a no-op, so the mark the handler now adds is the only
--- thing that re-solves the screen. Without it the drain would skip the screen
--- and no compose_screen would run. Proven via the solve counter; a contrast
--- (an explicit arrange does move the counter) keeps the zero-vs-nonzero
--- meaningful. No clients, so tree==scene has nothing to diverge under abort.
---
---   SOMEWM_TREE_ASSERT=abort make test-one TEST=tests/test-clay-screen-resize-resolves.lua
---------------------------------------------------------------------------

local runner = require("_runner")
local awful = require("awful")

assert(_somewm_clay, "this test requires the Clay engine (_somewm_clay)")

local function counts() return _somewm_clay.get_solve_counts() end

local fake

local function cleanup()
    if fake and fake.valid then fake:fake_remove() end
end
local function fail(msg) cleanup(); error(msg) end

local steps = {
    -- A second output offset past the primary, tile tag, no clients. Force an
    -- initial solve and wait for it to drain so the counter starts clean.
    function(count)
        if count == 1 then
            local pg = screen.primary.geometry
            fake = screen.fake_add(pg.x + pg.width, pg.y, 1280, 720)
            assert(fake and fake.valid, "fake_add failed")
            local ftag = fake.tags[1]
            ftag:view_only()
            ftag.gap = 0
            ftag.layout = require("awful.layout.clay").tile
            awful.layout.arrange(fake)
            return nil
        end
        if not _somewm_clay.is_stale(fake) then return true end
        if count >= 15 then fail("fake screen never settled") end
        return nil
    end,

    -- Pure size resize: same origin, new size, no client moves. The screen must
    -- still re-solve (compose_screen). Without the geometry mark this stays 0.
    function(count)
        if count == 1 then
            _somewm_clay.reset_solve_counts()
            fake:fake_resize(fake.geometry.x, fake.geometry.y, 1000, 800)
            return nil
        end
        if counts().compose_screen < 1 and count < 15 then return nil end
        assert(counts().compose_screen >= 1,
            "a pure screen resize must re-solve (compose_screen) via the geometry mark")
        io.stderr:write("[TEST] PASS: pure screen resize re-solves\n")
        return true
    end,

    -- Cleanup.
    function()
        cleanup()
        return true
    end,
}

runner.run_steps(steps)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
