---------------------------------------------------------------------------
--- Animated layout transitions for tiled clients.
--
-- Clay animates each tiled client's box from its previous place to the new
-- one. This module is the switch: awful.client.clay reads the duration into
-- every client frame a layout places, at the next arrange.
--
-- Usage in rc.lua:
--     local layout_anim = require("somewm.layout_animation")
--     layout_anim.duration = 0.15
--     layout_anim.enabled  = true   -- default
--
-- @module somewm.layout_animation
---------------------------------------------------------------------------

local gdebug = require("gears.debug")

local fields = {
    --- Animation duration in seconds.
    -- @tfield number duration
    duration = 0.15,

    --- Master switch. When false, layout changes snap instantly.
    -- @tfield boolean enabled
    enabled = true,
}

local layout_animation = setmetatable({}, {
    __index = fields,
    __newindex = function(_, key, value)
        if key == "duration" or key == "enabled" then
            fields[key] = value
        else
            gdebug.print_warning("somewm.layout_animation: " .. tostring(key) .. " is not a field")
        end
    end,
})

return layout_animation
