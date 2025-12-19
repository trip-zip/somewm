---------------------------------------------------------------------------
-- @author somewm contributors
-- @copyright 2025 somewm contributors
---------------------------------------------------------------------------

-- Track calls to C API functions
local input_settings_calls = {}
local keyboard_settings_calls = {}

-- Mock awesome C API
_G.awesome = setmetatable({
    _set_input_setting = function(key, value)
        table.insert(input_settings_calls, { key = key, value = value })
    end,
    _set_keyboard_setting = function(key, value)
        table.insert(keyboard_settings_calls, { key = key, value = value })
    end,
}, {
    __index = _G.awesome or {}
})

local input = require("awful.input")

describe("awful.input", function()
    before_each(function()
        -- Clear call tracking
        input_settings_calls = {}
        keyboard_settings_calls = {}
    end)

    describe("pointer/touchpad settings", function()
        it("tap_to_click default value", function()
            assert.is.equal(-1, input.tap_to_click)
        end)

        it("tap_to_click can be set", function()
            input.tap_to_click = 1
            assert.is.equal(1, input.tap_to_click)
        end)

        it("tap_to_click calls C API", function()
            input.tap_to_click = 1
            assert.is.equal(1, #input_settings_calls)
            assert.is.same({ key = "tap_to_click", value = 1 }, input_settings_calls[1])
        end)

        it("tap_and_drag default value", function()
            assert.is.equal(-1, input.tap_and_drag)
        end)

        it("tap_and_drag can be set", function()
            input.tap_and_drag = 0
            assert.is.equal(0, input.tap_and_drag)
        end)

        it("drag_lock default value", function()
            assert.is.equal(-1, input.drag_lock)
        end)

        it("natural_scrolling default value", function()
            assert.is.equal(-1, input.natural_scrolling)
        end)

        it("natural_scrolling can be set", function()
            input.natural_scrolling = 1
            assert.is.equal(1, input.natural_scrolling)
        end)

        it("disable_while_typing default value", function()
            assert.is.equal(-1, input.disable_while_typing)
        end)

        it("left_handed default value", function()
            assert.is.equal(-1, input.left_handed)
        end)

        it("middle_button_emulation default value", function()
            assert.is.equal(-1, input.middle_button_emulation)
        end)

        it("scroll_method default value", function()
            assert.is_nil(input.scroll_method)
        end)

        it("scroll_method can be set", function()
            input.scroll_method = "two_finger"
            assert.is.equal("two_finger", input.scroll_method)
        end)

        it("scroll_method accepts valid values", function()
            local valid_methods = { "no_scroll", "two_finger", "edge", "button" }
            for _, method in ipairs(valid_methods) do
                input.scroll_method = method
                assert.is.equal(method, input.scroll_method)
            end
        end)

        it("click_method default value", function()
            assert.is_nil(input.click_method)
        end)

        it("click_method can be set", function()
            input.click_method = "clickfinger"
            assert.is.equal("clickfinger", input.click_method)
        end)

        it("click_method accepts valid values", function()
            local valid_methods = { "none", "button_areas", "clickfinger" }
            for _, method in ipairs(valid_methods) do
                input.click_method = method
                assert.is.equal(method, input.click_method)
            end
        end)

        it("send_events_mode default value", function()
            assert.is_nil(input.send_events_mode)
        end)

        it("send_events_mode can be set", function()
            input.send_events_mode = "disabled"
            assert.is.equal("disabled", input.send_events_mode)
        end)

        it("accel_profile default value", function()
            assert.is_nil(input.accel_profile)
        end)

        it("accel_profile can be set", function()
            input.accel_profile = "flat"
            assert.is.equal("flat", input.accel_profile)
        end)

        it("accel_speed default value", function()
            assert.is.equal(0.0, input.accel_speed)
        end)

        it("accel_speed can be set", function()
            input.accel_speed = 0.5
            assert.is.equal(0.5, input.accel_speed)
        end)

        it("accel_speed accepts negative values", function()
            input.accel_speed = -0.8
            assert.is.equal(-0.8, input.accel_speed)
        end)

        it("tap_button_map default value", function()
            assert.is_nil(input.tap_button_map)
        end)

        it("tap_button_map can be set", function()
            input.tap_button_map = "lrm"
            assert.is.equal("lrm", input.tap_button_map)
        end)
    end)

    describe("keyboard settings", function()
        it("keyboard_repeat_rate default value", function()
            assert.is.equal(25, input.keyboard_repeat_rate)
        end)

        it("keyboard_repeat_rate can be set", function()
            input.keyboard_repeat_rate = 30
            assert.is.equal(30, input.keyboard_repeat_rate)
        end)

        it("keyboard_repeat_rate calls C API", function()
            input.keyboard_repeat_rate = 30
            assert.is.equal(1, #keyboard_settings_calls)
            assert.is.same({ key = "keyboard_repeat_rate", value = 30 }, keyboard_settings_calls[1])
        end)

        it("keyboard_repeat_delay default value", function()
            assert.is.equal(600, input.keyboard_repeat_delay)
        end)

        it("keyboard_repeat_delay can be set", function()
            input.keyboard_repeat_delay = 300
            assert.is.equal(300, input.keyboard_repeat_delay)
        end)

        it("xkb_layout default value", function()
            assert.is.equal("", input.xkb_layout)
        end)

        it("xkb_layout can be set", function()
            input.xkb_layout = "us"
            assert.is.equal("us", input.xkb_layout)
        end)

        it("xkb_layout accepts multiple layouts", function()
            input.xkb_layout = "us,ru"
            assert.is.equal("us,ru", input.xkb_layout)
        end)

        it("xkb_variant default value", function()
            assert.is.equal("", input.xkb_variant)
        end)

        it("xkb_variant can be set", function()
            input.xkb_variant = "dvorak"
            assert.is.equal("dvorak", input.xkb_variant)
        end)

        it("xkb_options default value", function()
            assert.is.equal("", input.xkb_options)
        end)

        it("xkb_options can be set", function()
            input.xkb_options = "ctrl:nocaps"
            assert.is.equal("ctrl:nocaps", input.xkb_options)
        end)

        it("xkb_options accepts multiple options", function()
            input.xkb_options = "ctrl:nocaps,compose:ralt"
            assert.is.equal("ctrl:nocaps,compose:ralt", input.xkb_options)
        end)
    end)

    describe("C API integration", function()
        it("pointer settings call _set_input_setting", function()
            input.tap_to_click = 1
            input.natural_scrolling = 1
            input.left_handed = 0

            assert.is.equal(3, #input_settings_calls)
            assert.is.equal(0, #keyboard_settings_calls)
        end)

        it("keyboard settings call _set_keyboard_setting", function()
            input.keyboard_repeat_rate = 30
            input.keyboard_repeat_delay = 400
            input.xkb_layout = "us"

            assert.is.equal(0, #input_settings_calls)
            assert.is.equal(3, #keyboard_settings_calls)
        end)

        it("mixed settings call appropriate C functions", function()
            input.tap_to_click = 1
            input.keyboard_repeat_rate = 30
            input.natural_scrolling = 1
            input.xkb_layout = "us"

            assert.is.equal(2, #input_settings_calls)
            assert.is.equal(2, #keyboard_settings_calls)
        end)
    end)

    describe("error handling", function()
        it("unknown property raises error on write", function()
            assert.has_error(function()
                input.nonexistent_property = 42
            end, "awful.input: unknown property 'nonexistent_property'")
        end)

        it("unknown property returns nil on read", function()
            assert.is_nil(input.nonexistent_property)
        end)
    end)

    describe("property value persistence", function()
        it("values persist across multiple reads", function()
            input.tap_to_click = 1
            assert.is.equal(1, input.tap_to_click)
            assert.is.equal(1, input.tap_to_click)
            assert.is.equal(1, input.tap_to_click)
        end)

        it("values can be changed multiple times", function()
            input.accel_speed = 0.5
            assert.is.equal(0.5, input.accel_speed)

            input.accel_speed = -0.3
            assert.is.equal(-0.3, input.accel_speed)

            input.accel_speed = 0.0
            assert.is.equal(0.0, input.accel_speed)
        end)
    end)

    describe("realistic usage scenarios", function()
        it("configure touchpad for tap-to-click and natural scrolling", function()
            input.tap_to_click = 1
            input.natural_scrolling = 1
            input.disable_while_typing = 1

            assert.is.equal(1, input.tap_to_click)
            assert.is.equal(1, input.natural_scrolling)
            assert.is.equal(1, input.disable_while_typing)
            assert.is.equal(3, #input_settings_calls)
        end)

        it("configure keyboard layout and repeat rate", function()
            input.xkb_layout = "us,ru"
            input.xkb_options = "grp:alt_shift_toggle"
            input.keyboard_repeat_rate = 35
            input.keyboard_repeat_delay = 250

            assert.is.equal("us,ru", input.xkb_layout)
            assert.is.equal("grp:alt_shift_toggle", input.xkb_options)
            assert.is.equal(35, input.keyboard_repeat_rate)
            assert.is.equal(250, input.keyboard_repeat_delay)
            assert.is.equal(4, #keyboard_settings_calls)
        end)

        it("configure left-handed mouse", function()
            input.left_handed = 1
            input.accel_profile = "flat"
            input.accel_speed = 0.0

            assert.is.equal(1, input.left_handed)
            assert.is.equal("flat", input.accel_profile)
            assert.is.equal(0.0, input.accel_speed)
        end)
    end)
end)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
