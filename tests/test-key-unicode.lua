-- Literal UTF-8 keys and canonically equivalent sequences resolve to the same
-- keysyms as their names, independently of the process character locale.

local awful = require("awful")

require("_runner").run_steps({
    function()
        local old_locale = os.setlocale(nil, "ctype")
        assert(os.setlocale("C", "ctype"))

        local cases = {
            { "ö", "odiaeresis" },
            { "ä", "adiaeresis" },
            { "ü", "udiaeresis" },
            { "o\204\136", "odiaeresis" },
            { "λ", "Greek_lambda" },
            { "€", "EuroSign" },
            { "😀", "U0001F600" },
            { "a", "a" },
            { "Return", "Return" },
            { "#38", "#38" },
        }
        for _, case in ipairs(cases) do
            local expected = key { key = case[2] }.key
            assert(key { key = case[1] }.key == expected,
                "Wrong keysym for " .. case[1])
            local binding = awful.key({ "Mod4" }, case[1], function() end)
            assert(binding[1].key == expected,
                "Wrong awful.key keysym for " .. case[1])
        end

        for _, invalid in ipairs({ "öö", "not_a_keysym", "\255", "\195", "o\0x" }) do
            assert(key { key = invalid }.key == "NoSymbol",
                "Invalid key string must not become a binding")
        end

        assert(os.setlocale(old_locale, "ctype"))
        return true
    end,
})
