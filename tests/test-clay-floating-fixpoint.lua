---------------------------------------------------------------------------
--- Test: the floating reflection is a fixpoint -- a static floating /
--- fullscreen / maximized client solved twice does not drift.
---
--- compose_screen reflects every non-tiled client at its live c:geometry() on
--- each solve (collect_floating). For a settled client that reflection is a
--- no-op resize (client_resize short-circuits on an equal area), so solving the
--- same scene twice must yield byte-identical geometry AND a byte-identical
--- solved `clay tree`. This is the #4 golden acceptance: no drift.
---
--- A plain terminal is the subject (no aspect-ratio / size-hint mutation that
--- would make a "no-op" resize move the box); the float case settles first to
--- absorb any cell-grid snap. One client stays tiled so the merged tile fills
--- the workarea and tree==scene holds.
---
---   SOMEWM_TREE_ASSERT=abort make test-one TEST=tests/test-clay-floating-fixpoint.lua
---------------------------------------------------------------------------

local runner = require("_runner")
local test_client = require("_client")
local utils = require("_utils")
local awful = require("awful")

if not test_client.is_available() then
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local clay = require("awful.layout.clay")
local ipc = require("awful.ipc")

local function counts() return _somewm_clay.get_solve_counts() end

local s = screen.primary
local tag = s.tags[1]
local wb, subject, tiled

-- Drive one solve and wait for the drain to finish: arrange only marks the
-- screen stale; the C drain solves + applies later. Returns true once the
-- screen is no longer stale and a merged solve has landed (nil = keep waiting).
local function solved(count, label)
    if count == 1 then
        _somewm_clay.reset_solve_counts()
        awful.layout.arrange(s)
        return nil
    end
    if (not _somewm_clay.is_stale(s)) and counts().merged >= 1 then
        return true
    end
    if count >= 15 then error(label .. ": solve never settled") end
    return nil
end

local function tree() return ipc.dispatch("clay tree " .. s.index, -1) end

-- Three measured-pair steps for one subject state. `enter` puts the subject in
-- the state; `verify` (optional) sanity-checks the state took after it drains.
local function fixpoint_case(label, enter, verify)
    local g1, t1
    return {
        -- Enter the state and let every cascaded arrange drain before measuring.
        function(count)
            if count == 1 then enter() end
            if _somewm_clay.is_stale(s) then
                if count >= 25 then error(label .. ": never drained on entry") end
                return nil
            end
            if verify then verify() end
            return true
        end,
        -- Measured solve 1: capture the settled geometry + solved tree.
        function(count)
            local r = solved(count, label .. " solve 1")
            if r ~= true then return r end
            g1 = subject:geometry()
            t1 = tree()
            assert(t1:find("cf_fix_subject", 1, true),
                label .. ": clay tree did not capture the subject"
                .. " (the t1==t2 compare would be vacuous)")
            return true
        end,
        -- Measured solve 2: must be byte-identical to solve 1 (no drift).
        function(count)
            local r = solved(count, label .. " solve 2")
            if r ~= true then return r end
            local g2 = subject:geometry()
            local t2 = tree()
            assert(g1.x == g2.x and g1.y == g2.y
                and g1.width == g2.width and g1.height == g2.height,
                string.format(
                    "%s: geometry drifted: (%d,%d %dx%d) -> (%d,%d %dx%d)",
                    label, g1.x, g1.y, g1.width, g1.height,
                    g2.x, g2.y, g2.width, g2.height))
            assert(t1 == t2,
                label .. ": solved clay tree drifted across two solves")
            io.stderr:write("[TEST] PASS: " .. label
                .. " solved twice is byte-identical (fixpoint)\n")
            return true
        end,
    }
end

local steps = {
    -- clay.tile + a top wibar so the workarea is strictly inside the geometry.
    function()
        tag:view_only()
        tag.gap = 0
        tag.layout = clay.tile
        wb = awful.wibar { position = "top", screen = s, height = 24 }
        return wb.visible and true or nil
    end,

    -- One client stays tiled (keeps the tile merged + the workarea filled for
    -- the abort assertion); one is the fixpoint subject.
    function(count)
        if count == 1 then
            test_client("cf_fix_tiled")
            test_client("cf_fix_subject")
        end
        tiled = utils.find_client_by_class("cf_fix_tiled")
        subject = utils.find_client_by_class("cf_fix_subject")
        return (tiled and subject) and true or nil
    end,
}

local function add(group) for _, st in ipairs(group) do steps[#steps + 1] = st end end

-- Fullscreen: C sets the subject box to screen.geometry (cleanest fixpoint).
add(fixpoint_case("fullscreen",
    function()
        subject.floating = false
        subject.maximized = false
        subject.fullscreen = true
    end,
    function() assert(subject.fullscreen, "subject did not become fullscreen") end))

-- Maximized: C sets the subject box to the workarea.
add(fixpoint_case("maximized",
    function()
        subject.fullscreen = false
        subject.maximized = true
    end,
    function()
        assert(subject.maximized and not subject.fullscreen,
            "subject did not become maximized")
    end))

-- Floating at an explicit box: settles once (cell-snap possible), then holds.
add(fixpoint_case("floating",
    function()
        subject.maximized = false
        subject.floating = true
        subject:geometry {
            x = s.geometry.x + 140, y = s.geometry.y + 110,
            width = 260, height = 180,
        }
    end,
    function() assert(subject.floating, "subject did not become floating") end))

-- Cleanup.
add({
    function(count)
        if count == 1 then
            if subject and subject.valid then subject.fullscreen = false end
            if wb then wb.visible = false end
            for _, c in ipairs(client.get()) do
                if c.valid then c:kill() end
            end
        end
        if #client.get() == 0 then return true end
        if count >= 12 then return true end
    end,
})

runner.run_steps(steps, { kill_clients = false })

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
