---------------------------------------------------------------------------
-- Test: re-declaring an unchanged scene mutates nothing
--
-- The Clay frame loop earns its keep only if a frame that declares the same
-- thing twice reconciles to zero scene mutations. Anything that churns per
-- declare (an element id derived from a counter, a raster redone because a
-- generation bumps unconditionally, a node reparented every pass) shows up
-- here as a non-zero second count while the screen looks perfectly fine.
--
-- awesome._test_redeclare() marks every output dirty and runs the declare,
-- solve and reconcile pass synchronously, returning the mutation count. Two
-- calls back to back have nothing in between that could change the scene, so
-- the second must be 0.
---------------------------------------------------------------------------

local runner = require("_runner")
local awful  = require("awful")
local wibox  = require("wibox")

local wb
local last_count, stable_samples = nil, 0

-- Re-declare twice: the first call absorbs whatever was genuinely pending,
-- the second must find the scene already correct.
local function second_pass_mutations()
    awesome._test_redeclare()
    return awesome._test_redeclare()
end

local function assert_zero(what)
    local n = second_pass_mutations()
    assert(n == 0, what .. ": re-declare mutated " .. n .. " nodes")
    io.stderr:write("[PASS] " .. what .. ": 0 mutations\n")
end

local steps = {
    -- Step 1: a wibox with a border and a textbox, then wait for the frame
    -- loop to go quiet so no genuine redraw is still in flight.
    function(count)
        if count == 1 then
            wb = wibox {
                x = 10, y = 10, width = 200, height = 30,
                bg = "#202020", border_width = 2, border_color = "#ff0000",
                visible = true,
                screen = awful.screen.focused(),
            }
            wb:setup { text = "declare", widget = wibox.widget.textbox }
            return nil
        end

        local now = awesome._test_frame_count
        stable_samples = (last_count ~= nil and now == last_count)
            and stable_samples + 1 or 0
        last_count = now
        return stable_samples >= 3 or nil
    end,

    -- Step 2: the settled scene re-declares to nothing.
    function()
        assert_zero("settled wibox scene")
        return true
    end,

    -- Step 3: a real change mutates, and the scene is stable again after it.
    function()
        wb.x = wb.x + 25
        assert(awesome._test_redeclare() > 0,
            "moving the wibox mutated nothing")
        assert_zero("after a wibox move")
        return true
    end,

    -- Step 4: same across a tag switch, which rebuilds every band.
    function()
        local s = awful.screen.focused()
        local other = s.tags[2] or s.tags[1]
        other:view_only()
        assert_zero("after a tag switch")
        s.tags[1]:view_only()
        return true
    end,

    function()
        wb.visible = false
        return true
    end,
}

runner.run_steps(steps)
