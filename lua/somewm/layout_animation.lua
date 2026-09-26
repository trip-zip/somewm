---------------------------------------------------------------------------
--- Animated layout transitions for tiled clients.
--
-- Clay animates each tiled client's box from its previous place to the new
-- one. This module is the switch: the duration it pushes reaches every
-- client allocated by a layout.
--
-- Usage in rc.lua:
--     local layout_anim = require("somewm.layout_animation")
--     layout_anim.duration = 0.15
--     layout_anim.easing   = "ease-out-cubic"
--     layout_anim.enabled  = true   -- default
--
-- @module somewm.layout_animation
---------------------------------------------------------------------------

local capi = { awesome = awesome }

local fields = {
    --- Animation duration in seconds.
    -- @tfield number duration
    duration = 0.15,

    --- Accepted and ignored: Clay eases out.
    -- @tfield string easing
    easing = "ease-out-cubic",

    --- Master switch. When false, layout changes snap instantly.
    -- @tfield boolean enabled
    enabled = true,
}

local function push()
    capi.awesome._clay_client_transition(fields.enabled and fields.duration or 0)
end

local layout_animation = setmetatable({}, {
    __index = fields,
    __newindex = function(_, key, value)
        fields[key] = value
        push()
    end,
})

push()

return layout_animation
