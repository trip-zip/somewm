-- Run with LC_ALL=C.UTF-8 to exercise character-locale initialization at startup.
-- Input goes through the C keygrabber and the real prompt's UTF-8 length check.

local awful = require("awful")
local wibox = require("wibox")
local menubar = require("menubar")

local old_layout, old_variant

local function type_umlauts()
    for _, name in ipairs({ "adiaeresis", "odiaeresis", "udiaeresis" }) do
        assert(_keygrabber.inject(name, true))
        assert(_keygrabber.inject(name, false))
    end
end

require("_runner").run_steps({
    function()
        assert(("ö"):wlen() == 1, "Startup must adopt the UTF-8 character locale")
        assert(os.setlocale(nil, "numeric") == "C", "Numeric locale must stay unchanged")
        old_layout, old_variant = awful.input.xkb_layout, awful.input.xkb_variant
        awful.input.xkb_layout = "de"
        awful.input.xkb_variant = "neo"
        return true
    end,
    function()
        local command, submitted
        awful.prompt.run {
            textbox = wibox.widget.textbox(),
            changed_callback = function(value) command = value end,
            exe_callback = function(value) submitted = value end,
        }
        type_umlauts()
        assert(command == "äöü", "Prompt must accept umlauts")
        _keygrabber.inject("BackSpace", true)
        _keygrabber.inject("BackSpace", false)
        assert(command == "äö", "Backspace must remove a whole UTF-8 character")
        _keygrabber.inject("Return", true)
        assert(submitted == "äö", "Prompt must submit the UTF-8 text")
        return true
    end,
    function()
        local command
        local promptbox = awful.widget.prompt {
            changed_callback = function(value) command = value end,
        }
        promptbox:run()
        type_umlauts()
        assert(command == "äöü", "Run widget must accept umlauts")
        _keygrabber.inject("Escape", true)
        return true
    end,
    function()
        local command
        local old_args = menubar.prompt_args
        menubar.prompt_args = {
            changed_callback = function(value) command = value end,
        }
        menubar.show()
        type_umlauts()
        assert(command == "äöü", "Menubar prompt must accept umlauts")
        _keygrabber.inject("Escape", true)
        menubar.prompt_args = old_args
        awful.input.xkb_variant = old_variant or ""
        awful.input.xkb_layout = old_layout or "us"
        return true
    end,
})
