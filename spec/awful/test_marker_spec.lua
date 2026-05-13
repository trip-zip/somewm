-- Validates the Mod4 -> Mod1 substitution used by awful.test_marker.
-- .apply() mutates capi.root.keys; this spec covers only the pure helper.

local tm = require("awful.test_marker")

describe("awful.test_marker.substitute_modifiers", function()
    it("replaces Mod4 with Mod1 and reports changed=true", function()
        local out, changed = tm.substitute_modifiers({ "Mod4" })
        assert.are.same({ "Mod1" }, out)
        assert.is_true(changed)
    end)

    it("preserves other modifiers around Mod4", function()
        local out, changed = tm.substitute_modifiers({ "Mod4", "Shift" })
        assert.are.same({ "Mod1", "Shift" }, out)
        assert.is_true(changed)
    end)

    it("preserves order and replaces Mod4 in the middle", function()
        local out, changed = tm.substitute_modifiers({ "Control", "Mod4", "Shift" })
        assert.are.same({ "Control", "Mod1", "Shift" }, out)
        assert.is_true(changed)
    end)

    it("leaves bindings without Mod4 untouched and reports changed=false", function()
        local out, changed = tm.substitute_modifiers({ "Control", "Shift" })
        assert.are.same({ "Control", "Shift" }, out)
        assert.is_false(changed)
    end)

    it("returns an empty table unchanged", function()
        local out, changed = tm.substitute_modifiers({})
        assert.are.same({}, out)
        assert.is_false(changed)
    end)

    it("does not alias the input table", function()
        local input = { "Mod4" }
        local out = tm.substitute_modifiers(input)
        out[1] = "tampered"
        assert.are.same({ "Mod4" }, input)
    end)
end)
