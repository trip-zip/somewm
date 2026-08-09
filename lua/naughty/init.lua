---------------------------------------------------------------------------
-- Desktop notification handling library.
--
-- @author Uli Schlachter &lt;psychon@znc.in&gt;
-- @copyright 2014 Uli Schlachter
-- @module naughty
---------------------------------------------------------------------------

local naughty = require("naughty.core")
local gdebug = require("gears.debug")
local ascreen = require("awful.screen")
local capi = {awesome = awesome, screen = screen}
if dbus then
    naughty.dbus = require("naughty.dbus")
end

naughty.action = require("naughty.action")
naughty.list = require("naughty.list")
naughty.layout = require("naughty.layout")
naughty.widget = require("naughty.widget")
naughty.container = require("naughty.container")
naughty.action = require("naughty.action")
naughty.notification = require("naughty.notification")

-- An error this early has no screen to display a notification on, so log it
-- and skip the popup.
--
-- capi.screen.count() is not enough: after a config timeout the Lua state
-- is rebuilt while the screen refs still point at the closed one, so the
-- compositor reports screens that no notification can be placed on.
local function can_display()
    if capi.screen.count() > 0 and ascreen.focused() then
        return true
    end

    gdebug.print_warning("An error occurred before a screen was added")
    return false
end

-- Handle runtime errors during startup
if capi.awesome.startup_errors then

    -- Wait until `rc.lua` is executed before creating the notifications.
    -- Otherwise nothing is handling them (yet).
    client.connect_signal("scanning", function()
        -- A lot of things have to go wrong for this to happen, but it can.
        if not can_display() then
            gdebug.print_error(capi.awesome.startup_errors)
            return
        end

        naughty.emit_signal(
            "request::display_error", capi.awesome.startup_errors, true
        )
    end)
end

-- Handle runtime errors after startup
do
    local in_error = false

    capi.awesome.connect_signal("debug::error", function (err)
        -- Make sure we don't go into an endless error loop
        if in_error then return end

        in_error = true

        if can_display() then
            naughty.emit_signal("request::display_error", tostring(err), false)
        else
            gdebug.print_error(err)
        end

        in_error = false
    end)

end

return naughty

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
