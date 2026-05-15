-- max stacks every client at the workarea (topmost visible). Clay's
-- apply pass writes the workarea minus border_width to each client
-- uniformly, replacing the imperative clients[2..n] loop.

local layout = require("somewm.layout")

local function build_stack()
    -- The stack only contributes floating children to its parent's
    -- sizing pass and can't grow on its own at the root. The row
    -- inherits grow=true from the adapter; the stack fills the row
    -- via flex-fill default sizing.
    return layout.row {
        layout.stack { children = layout.all() },
    }
end

return function(clay)
    clay.max = clay.layout {
        name           = "clay.max",
        body_signature = "context",
        skip_gap       = function() return true end,
        no_gap         = true,
        body           = build_stack,
    }

    -- Fullscreen variant: same body, but solves against screen.geometry
    -- (including wibar regions) instead of the workarea.
    clay.max.fullscreen = clay.layout {
        name           = "clay.fullscreen",
        body_signature = "context",
        skip_gap       = function() return true end,
        no_gap         = true,
        bounds_source  = "geometry",
        body           = build_stack,
    }
end
