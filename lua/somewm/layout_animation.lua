local animation = require("somewm.animation")
animation.layout_duration = 0.15
local fields = {duration = "layout_duration", enabled = "enabled"}

return setmetatable({}, {
    __index = function(_, key) return animation[fields[key] or key] end,
    __newindex = function(_, key, value) animation[fields[key] or key] = value end,
})
