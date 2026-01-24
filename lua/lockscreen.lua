---------------------------------------------------------------------------
--- Default lockscreen module for somewm.
--
-- Provides a simple but complete lockscreen with visual feedback.
--
-- Usage:
--    require("lockscreen").init()
--    -- Then bind awesome.lock to a key, e.g.:
--    awful.key({ modkey }, "l", awesome.lock)
--
-- @module lockscreen
---------------------------------------------------------------------------

local wibox = require("wibox")
local awful = require("awful")
local gears = require("gears")

local lockscreen = {}

-- State
local surface = nil
local password = ""
local grabber = nil

-- Widget references
local password_dots = nil
local status_text = nil
local clock = nil

-- Configuration
local config = {
    bg_color = "#1a1a2e",
    fg_color = "#e0e0e0",
    input_bg = "#2a2a4e",
    border_color = "#4a4a6e",
    error_color = "#ff6b6b",
    font = "sans 14",
    font_large = "sans bold 48",
}

--- Initialize the lockscreen module
-- @tparam[opt] table opts Configuration options
function lockscreen.init(opts)
    opts = opts or {}
    for k, v in pairs(opts) do
        if config[k] ~= nil then config[k] = v end
    end

    -- Clock widget
    clock = wibox.widget({
        format = "%H:%M",
        font = config.font_large,
        halign = "center",
        widget = wibox.widget.textclock,
    })

    -- Password dots display
    password_dots = wibox.widget({
        text = "",
        font = config.font,
        halign = "center",
        valign = "center",
        widget = wibox.widget.textbox,
    })

    -- Status/instruction text
    status_text = wibox.widget({
        text = "Enter password to unlock",
        font = config.font,
        halign = "center",
        widget = wibox.widget.textbox,
    })

    -- Input box with border
    local input_box = wibox.widget({
        {
            {
                password_dots,
                left = 20,
                right = 20,
                top = 12,
                bottom = 12,
                widget = wibox.container.margin,
            },
            bg = config.input_bg,
            widget = wibox.container.background,
        },
        margins = 2,
        color = config.border_color,
        widget = wibox.container.margin,
    })

    -- Constrain input box width
    local input_container = wibox.widget({
        input_box,
        forced_width = 280,
        forced_height = 48,
        widget = wibox.container.constraint,
    })

    -- Main layout
    local layout = wibox.widget({
        {
            {
                -- Clock
                {
                    clock,
                    fg = config.fg_color,
                    widget = wibox.container.background,
                },
                -- Spacer
                {
                    forced_height = 40,
                    widget = wibox.container.background,
                },
                -- Input box (centered)
                {
                    input_container,
                    halign = "center",
                    widget = wibox.container.place,
                },
                -- Status text
                {
                    {
                        status_text,
                        fg = config.fg_color,
                        widget = wibox.container.background,
                    },
                    top = 16,
                    widget = wibox.container.margin,
                },
                spacing = 8,
                layout = wibox.layout.fixed.vertical,
            },
            halign = "center",
            valign = "center",
            widget = wibox.container.place,
        },
        bg = config.bg_color,
        widget = wibox.container.background,
    })

    -- Create the lock surface
    local s = screen.primary
    surface = wibox({
        visible = false,
        ontop = true,
        bg = config.bg_color,
        x = s.geometry.x,
        y = s.geometry.y,
        width = s.geometry.width,
        height = s.geometry.height,
        widget = layout,
    })

    -- Register with somewm
    awesome:set_lock_surface(surface)

    -- Helper to set status
    local function set_status(text, is_error)
        local color = is_error and config.error_color or config.fg_color
        status_text.markup = string.format('<span foreground="%s">%s</span>', color, text)
    end

    -- Handle lock activation
    awesome.connect_signal("lock::activate", function()
        password = ""
        password_dots.text = ""
        set_status("Enter password to unlock", false)
        surface.visible = true

        grabber = awful.keygrabber({
            autostart = true,
            stop_key = nil,
            keypressed_callback = function(_, _, key, _)
                if key == "Return" then
                    set_status("Verifying...", false)
                    gears.timer.start_new(0.05, function()
                        if awesome:authenticate(password) then
                            awesome:unlock()
                        else
                            password = ""
                            password_dots.text = ""
                            set_status("Wrong password, try again", true)
                            gears.timer.start_new(2, function()
                                if surface.visible then
                                    set_status("Enter password to unlock", false)
                                end
                                return false
                            end)
                        end
                        return false
                    end)
                elseif key == "BackSpace" then
                    password = password:sub(1, -2)
                    password_dots.text = string.rep("●", #password)
                elseif key == "Escape" then
                    password = ""
                    password_dots.text = ""
                elseif #key == 1 then
                    password = password .. key
                    password_dots.text = string.rep("●", #password)
                end
            end,
        })
    end)

    -- Handle unlock
    awesome.connect_signal("lock::deactivate", function()
        surface.visible = false
        password = ""
        password_dots.text = ""
        if grabber then
            grabber:stop()
            grabber = nil
        end
    end)
end

return lockscreen
