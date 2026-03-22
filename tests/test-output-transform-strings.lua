---------------------------------------------------------------------------
-- Tests for output transform string setter:
--   1. Setting transform with integer values works
--   2. Setting transform with string values ("normal", "90", etc.) works
--   3. Reading transform always returns an integer
--   4. Invalid string raises error
--   5. Out-of-range integer raises error
---------------------------------------------------------------------------

local runner = require("_runner")

print("TEST: Starting output-transform-strings test")

local steps = {
    -- Step 1: Integer transform values work
    function()
        print("TEST: Step 1 - Integer transform values")
        local o = output[1]
        assert(o ~= nil and o.valid, "output[1] not valid")

        -- Save original transform
        local original = o.transform

        -- Set to 0 (normal)
        o.transform = 0
        assert(o.transform == 0, "expected 0, got " .. o.transform)

        -- Restore original
        o.transform = original
        print("TEST:   integer transform OK")
        return true
    end,

    -- Step 2: String transform values work
    function()
        print("TEST: Step 2 - String transform values")
        local o = output[1]

        -- "normal" -> 0
        o.transform = "normal"
        assert(o.transform == 0,
            "expected 0 for 'normal', got " .. o.transform)
        print("TEST:   'normal' -> " .. o.transform)

        -- "90" -> 1
        o.transform = "90"
        assert(o.transform == 1,
            "expected 1 for '90', got " .. o.transform)
        print("TEST:   '90' -> " .. o.transform)

        -- "180" -> 2
        o.transform = "180"
        assert(o.transform == 2,
            "expected 2 for '180', got " .. o.transform)
        print("TEST:   '180' -> " .. o.transform)

        -- "270" -> 3
        o.transform = "270"
        assert(o.transform == 3,
            "expected 3 for '270', got " .. o.transform)
        print("TEST:   '270' -> " .. o.transform)

        -- Reset to normal
        o.transform = "normal"
        print("TEST:   string transforms OK")
        return true
    end,

    -- Step 3: Flipped string values work
    function()
        print("TEST: Step 3 - Flipped string values")
        local o = output[1]

        -- "flipped" -> 4
        o.transform = "flipped"
        assert(o.transform == 4,
            "expected 4 for 'flipped', got " .. o.transform)
        print("TEST:   'flipped' -> " .. o.transform)

        -- "flipped-90" -> 5
        o.transform = "flipped-90"
        assert(o.transform == 5,
            "expected 5 for 'flipped-90', got " .. o.transform)
        print("TEST:   'flipped-90' -> " .. o.transform)

        -- "flipped_90" (underscore variant) -> 5
        o.transform = "flipped_90"
        assert(o.transform == 5,
            "expected 5 for 'flipped_90', got " .. o.transform)
        print("TEST:   'flipped_90' -> " .. o.transform)

        -- "flipped-180" -> 6
        o.transform = "flipped-180"
        assert(o.transform == 6,
            "expected 6 for 'flipped-180', got " .. o.transform)
        print("TEST:   'flipped-180' -> " .. o.transform)

        -- "flipped-270" -> 7
        o.transform = "flipped-270"
        assert(o.transform == 7,
            "expected 7 for 'flipped-270', got " .. o.transform)
        print("TEST:   'flipped-270' -> " .. o.transform)

        -- Reset to normal
        o.transform = 0
        print("TEST:   flipped string transforms OK")
        return true
    end,

    -- Step 4: Transform getter always returns integer
    function()
        print("TEST: Step 4 - Transform getter returns integer")
        local o = output[1]

        o.transform = "180"
        assert(type(o.transform) == "number",
            "expected number, got " .. type(o.transform))
        assert(o.transform == 2, "expected 2, got " .. o.transform)

        o.transform = 0
        print("TEST:   getter returns integer OK")
        return true
    end,

    -- Step 5: Invalid string raises error
    function()
        print("TEST: Step 5 - Invalid string raises error")
        local o = output[1]

        local ok, err = pcall(function()
            o.transform = "upside-down"
        end)
        assert(not ok, "expected error for invalid transform string")
        assert(err:match("invalid transform string"),
            "error message should mention invalid transform string: " .. err)
        print("TEST:   invalid string error: " .. err)
        return true
    end,

    -- Step 6: Out-of-range integer raises error
    function()
        print("TEST: Step 6 - Out-of-range integer raises error")
        local o = output[1]

        local ok, err = pcall(function()
            o.transform = 8
        end)
        assert(not ok, "expected error for transform=8")
        print("TEST:   out-of-range error: " .. err)

        local ok2, err2 = pcall(function()
            o.transform = -1
        end)
        assert(not ok2, "expected error for transform=-1")
        print("TEST:   negative error: " .. err2)

        return true
    end,
}

runner.run_steps(steps)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
