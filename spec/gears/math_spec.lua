---------------------------------------------------------------------------
-- @author somewm contributors
-- @copyright 2025 somewm contributors
---------------------------------------------------------------------------

local gmath = require("gears.math")

describe("gears.math", function()
    describe("round", function()
        it("rounds numbers down", function()
            assert.is.equal(5, gmath.round(5.4))
        end)

        it("rounds numbers up", function()
            assert.is.equal(6, gmath.round(5.5))
        end)

        it("handles negative numbers", function()
            assert.is.equal(-5, gmath.round(-5.4))
            assert.is.equal(-5, gmath.round(-5.5))
        end)

        it("handles zero", function()
            assert.is.equal(0, gmath.round(0))
        end)
    end)

    describe("cycle", function()
        it("cycles index within length", function()
            assert.is.equal(1, gmath.cycle(4, 5))
            assert.is.equal(4, gmath.cycle(4, 0))
            assert.is.equal(2, gmath.cycle(4, 2))
        end)

        it("returns nil for invalid length", function()
            assert.is_nil(gmath.cycle(0, 1))
            assert.is_nil(gmath.cycle(-1, 1))
        end)
    end)
end)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
