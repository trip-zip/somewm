--- Test that a "0"-leading map_from_region/map_to_region string parses.
--
-- input_rule_get_region() parsed "X1xY1 X2xY2" strings with
-- sscanf(raw, "%lfx%lf %lfx%lf", ...). glibc's %lf conversion also accepts
-- C99 hex-float syntax, and permissively treats a bare "0x0" (no required
-- 'p' exponent) as the complete value 0.0 - so the first %lf silently
-- swallowed the "0x" of a "0x0 ..." string as a hex-float lead-in instead
-- of stopping at the intended 'x' separator, breaking any region string
-- whose first coordinate is 0 - the natural top-left corner, so the single
-- most common value anyone would type (#692).

local input = require("awful.input")

local steps = {}

table.insert(steps, function()
    local ok, err = pcall(function()
        input.rules = {
            { rule = { type = "tablet" },
              properties = { map_from_region = "0x0 0.5x0.5" } },
        }
    end)

    assert(ok, "regression: a '0x0 ...' map_from_region string raised an "
        .. "error: " .. tostring(err))

    return true
end)

table.insert(steps, function()
    -- map_to_region shares the same parser - same coverage.
    local ok, err = pcall(function()
        input.rules = {
            { rule = { type = "tablet" },
              properties = { map_to_region = "0x0 100x100" } },
        }
    end)

    assert(ok, "regression: a '0x0 ...' map_to_region string raised an "
        .. "error: " .. tostring(err))

    return true
end)

table.insert(steps, function()
    -- The parser should still reject genuinely malformed strings.
    local ok = pcall(function()
        input.rules = {
            { rule = { type = "tablet" },
              properties = { map_from_region = "garbage" } },
        }
    end)

    assert(not ok, "malformed map_from_region string should still error")

    -- Clear the rule so it doesn't leak into later tests.
    input.rules = {}

    return true
end)

require("_runner").run_steps(steps)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
