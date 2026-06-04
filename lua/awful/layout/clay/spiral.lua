-- Spiral / dwindle: recursive 50/50 splits, each level rotating the
-- split direction. Spiral cycles through 4 quadrants (depth % 4);
-- dwindle alternates between 2 (depth % 2). Master gets mwfact share at
-- depth 0; subsequent splits are even halves.

local layout = require("somewm.layout")

return function(clay)
    local function build(clients, idx, depth, mwfact, is_spiral)
        if idx == #clients then
            return layout.row { layout.client(clients[idx]) }
        end

        local fact          = (idx == 1) and mwfact or 0.5
        local quadrant      = is_spiral and (depth % 4) or (depth % 2)
        local is_row        = (quadrant % 2 == 0)
        local current_first = (quadrant == 0 or quadrant == 1)

        local container = is_row and layout.row    or layout.column
        local size_key  = is_row and "width"       or "height"
        local cross     = is_row and layout.column or layout.row

        local current = cross {
            [size_key] = layout.percent(fact * 100),
            layout.client(clients[idx]),
        }
        local rest = build(clients, idx + 1, depth + 1, mwfact, is_spiral)

        if current_first then
            return container { current, rest }
        else
            return container { rest, current }
        end
    end

    local function spiral_build(is_spiral)
        return function(ctx)
            local clients = ctx.children
            if #clients == 0 then return nil end
            return build(clients, 1, 0, ctx.props.master_width_factor, is_spiral)
        end
    end

    clay.spiral = clay.layout {
        name           = "clay.spiral",
        body_signature = "context",
        body           = spiral_build(true),
    }
    clay.spiral.dwindle = clay.layout {
        name           = "clay.dwindle",
        body_signature = "context",
        body           = spiral_build(false),
    }
end
