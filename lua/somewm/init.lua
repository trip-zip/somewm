---------------------------------------------------------------------------
--- somewm extensions namespace.
--
-- Modules under somewm.* are compositor-specific additions that do not exist
-- in upstream AwesomeWM.  They must never modify the sacred awful/gears/wibox
-- libraries.
--
-- Submodules are loaded lazily so that `require("somewm")` does not install
-- signal handlers or other side effects until a submodule is actually used.
--
-- @module somewm
---------------------------------------------------------------------------

local submodules = {
    layout_animation = "somewm.layout_animation",
    tag_slide        = "somewm.tag_slide",
}

return setmetatable({}, {
    __index = function(self, key)
        local mod_path = submodules[key]
        if mod_path then
            local mod = require(mod_path)
            rawset(self, key, mod)
            return mod
        end
    end,
})
