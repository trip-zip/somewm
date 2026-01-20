---------------------------------------------------------------------------
--- Input device configuration for libinput and keyboard settings.
--
-- This module provides configuration for pointer/touchpad devices (via libinput)
-- and keyboard settings (XKB layout, repeat rate). These are somewm-specific
-- additions since AwesomeWM on X11 delegates input configuration to xinput.
--
-- @author somewm contributors
-- @copyright 2025 somewm contributors
-- @module awful.input
---------------------------------------------------------------------------

local capi = { awesome = awesome }

--- The input configuration module.
-- @table awful.input
local module = {}

-- Internal state for all settings
local state = {
    -- Pointer/touchpad settings (libinput)
    tap_to_click = -1,              -- 0=off, 1=on, -1=device default
    tap_and_drag = -1,
    drag_lock = -1,
    tap_3fg_drag = -1,              -- 0=off, 1=on (three-finger drag), -1=device default
    natural_scrolling = -1,
    disable_while_typing = -1,
    dwtp = -1,                      -- 0=off, 1=on (disable while trackpoint), -1=device default
    left_handed = -1,
    middle_button_emulation = -1,
    scroll_method = nil,            -- "no_scroll", "two_finger", "edge", "button"
    scroll_button = 0,              -- button number for scroll-on-button mode
    scroll_button_lock = -1,        -- 0=hold, 1=toggle, -1=device default
    click_method = nil,             -- "none", "button_areas", "clickfinger"
    clickfinger_button_map = nil,   -- "lrm", "lmr"
    send_events_mode = nil,         -- "enabled", "disabled", "disabled_on_external_mouse"
    accel_profile = nil,            -- "flat", "adaptive"
    accel_speed = 0.0,              -- -1.0 to 1.0
    tap_button_map = nil,           -- "lrm", "lmr"

    -- Keyboard settings
    keyboard_repeat_rate = 25,      -- repeats per second
    keyboard_repeat_delay = 600,    -- ms before repeat starts
    xkb_layout = "",                -- keyboard layout (e.g., "us", "us,ru")
    xkb_variant = "",               -- layout variant (e.g., "dvorak")
    xkb_options = "",               -- XKB options (e.g., "ctrl:nocaps")
}

-- Mapping from property names to their types for validation
local property_types = {
    tap_to_click = "int",
    tap_and_drag = "int",
    drag_lock = "int",
    tap_3fg_drag = "int",
    natural_scrolling = "int",
    disable_while_typing = "int",
    dwtp = "int",
    left_handed = "int",
    middle_button_emulation = "int",
    scroll_method = "string",
    scroll_button = "int",
    scroll_button_lock = "int",
    click_method = "string",
    clickfinger_button_map = "string",
    send_events_mode = "string",
    accel_profile = "string",
    accel_speed = "number",
    tap_button_map = "string",
    keyboard_repeat_rate = "int",
    keyboard_repeat_delay = "int",
    xkb_layout = "string",
    xkb_variant = "string",
    xkb_options = "string",
}

-- Properties that are pointer/input device settings (vs keyboard)
local pointer_settings = {
    tap_to_click = true,
    tap_and_drag = true,
    drag_lock = true,
    tap_3fg_drag = true,
    natural_scrolling = true,
    disable_while_typing = true,
    dwtp = true,
    left_handed = true,
    middle_button_emulation = true,
    scroll_method = true,
    scroll_button = true,
    scroll_button_lock = true,
    click_method = true,
    clickfinger_button_map = true,
    send_events_mode = true,
    accel_profile = true,
    accel_speed = true,
    tap_button_map = true,
}

-- Set up metatable for property access
setmetatable(module, {
    __index = function(_, key)
        if state[key] ~= nil then
            return state[key]
        end
        return nil
    end,

    __newindex = function(_, key, value)
        -- Check if property exists using property_types table
        if property_types[key] == nil then
            error("awful.input: unknown property '" .. tostring(key) .. "'")
        end

        -- Store the value
        state[key] = value

        -- Apply to devices via C helper functions
        if pointer_settings[key] then
            -- Pointer/touchpad setting - call C to apply to all devices
            capi.awesome._set_input_setting(key, value)
        else
            -- Keyboard setting - call C to apply
            capi.awesome._set_keyboard_setting(key, value)
        end
    end,
})

return module
