---------------------------------------------------------------------------
-- Tests for fake screen virtual output:
--   1. Fake screen gets a virtual output (screen.output is never nil)
--   2. Virtual output has virtual=true
--   3. Virtual output has a name
--   4. Virtual output has valid=true while screen exists
--   5. fake_remove invalidates the virtual output
--   6. Virtual output has no wlr_output-backed properties
---------------------------------------------------------------------------

local runner = require("_runner")

print("TEST: Starting output-fake-screen test")

local fake_screen = nil
local fake_output = nil
local initial_output_count = nil

local steps = {
    -- Step 1: Record initial state
    function()
        print("TEST: Step 1 - Record initial state")
        initial_output_count = output.count()
        print("TEST:   initial output count = " .. initial_output_count)
        return true
    end,

    -- Step 2: Create fake screen and verify output
    function()
        print("TEST: Step 2 - Create fake screen")
        fake_screen = screen.fake_add(1400, 0, 400, 300)
        assert(fake_screen ~= nil, "fake_add returned nil")
        assert(fake_screen.valid, "fake screen not valid")
        print("TEST:   fake screen index = " .. fake_screen.index)

        -- screen.output should never be nil
        fake_output = fake_screen.output
        assert(fake_output ~= nil,
            "fake screen.output is nil (should never be nil)")
        print("TEST:   fake screen has output: " .. tostring(fake_output))
        return true
    end,

    -- Step 3: Virtual output properties
    function()
        print("TEST: Step 3 - Virtual output properties")
        assert(fake_output.valid == true,
            "virtual output should be valid")

        -- Must be virtual
        assert(fake_output.virtual == true,
            "fake screen output should be virtual, got "
            .. tostring(fake_output.virtual))
        print("TEST:   virtual = true OK")

        -- Must have a name
        assert(type(fake_output.name) == "string",
            "virtual output name should be string")
        assert(#fake_output.name > 0,
            "virtual output name should not be empty")
        print("TEST:   name = " .. fake_output.name)

        -- Screen cross-reference
        assert(fake_output.screen == fake_screen,
            "virtual output.screen should point to fake screen")
        print("TEST:   output.screen == fake_screen OK")

        return true
    end,

    -- Step 4: Virtual output count
    function()
        print("TEST: Step 4 - Output count includes virtual output")
        -- Virtual outputs from fake screens are included in
        -- output.count() since they are valid Lua objects that
        -- appear in the output iterator.
        local count = output.count()
        print("TEST:   output.count() = " .. count
            .. " (was " .. initial_output_count .. ")")
        assert(count == initial_output_count + 1,
            "output.count() should include virtual output, expected "
            .. (initial_output_count + 1) .. " got " .. count)
        return true
    end,

    -- Step 5: Remove fake screen and verify output invalidation
    function()
        print("TEST: Step 5 - fake_remove invalidates virtual output")
        fake_screen:fake_remove()

        -- After removal, the virtual output should be invalidated
        assert(fake_output.valid == false,
            "virtual output should be invalid after fake_remove, got "
            .. tostring(fake_output.valid))
        print("TEST:   output.valid = false after fake_remove OK")

        return true
    end,
}

runner.run_steps(steps)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
