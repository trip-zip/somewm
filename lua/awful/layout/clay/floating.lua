-- Floating routes through Clay as a stack of self-positioned clients:
-- the solve is a no-op for positioning (each client's current rect goes
-- in, the same rect comes out), but the apply pass runs through the
-- unified pipeline. Width/height carry +bw2 to compensate for the
-- decoration sub-pass's bw2 subtraction so c:geometry() round-trips
-- exactly.

local ipairs = ipairs
local layout = require("somewm.layout")
local capi = {
    mouse        = mouse,
    mousegrabber = mousegrabber,
}

local resize_jump_to_corner = true

local function mouse_resize_handler(c, corner, x, y)
    local g = c:geometry()

    -- Do not allow maximized clients to be resized by mouse.
    local fixed_x = c.maximized_horizontal
    local fixed_y = c.maximized_vertical

    local prev_coords = {}
    local coordinates_delta = { x = 0, y = 0 }

    if resize_jump_to_corner then
        capi.mouse.coords({ x = x, y = y })
    else
        local corner_x, corner_y = x, y
        local mouse_coords = capi.mouse.coords()
        x = mouse_coords.x
        y = mouse_coords.y
        coordinates_delta = { x = corner_x - x, y = corner_y - y }
    end

    capi.mousegrabber.run(function(state)
        if not c.valid then return false end

        state.x = state.x + coordinates_delta.x
        state.y = state.y + coordinates_delta.y

        for _, v in ipairs(state.buttons) do
            if v then
                local ng

                prev_coords = { x = state.x, y = state.y }

                if corner == "bottom_right" then
                    ng = { width = state.x - g.x, height = state.y - g.y }
                elseif corner == "bottom_left" then
                    ng = { x = state.x, width = (g.x + g.width) - state.x,
                           height = state.y - g.y }
                elseif corner == "top_left" then
                    ng = { x = state.x, width = (g.x + g.width) - state.x,
                           y = state.y, height = (g.y + g.height) - state.y }
                else
                    ng = { width = state.x - g.x, y = state.y,
                           height = (g.y + g.height) - state.y }
                end

                if ng.width <= 0 then ng.width = nil end
                if ng.height <= 0 then ng.height = nil end
                if fixed_x then
                    ng.width = g.width
                    ng.x = g.x
                end
                if fixed_y then
                    ng.height = g.height
                    ng.y = g.y
                end

                c:geometry(ng)
                -- Read the geometry that was actually applied so we can
                -- correct for size hints that may have clamped the new
                -- width/height.
                local rg = c:geometry()

                if corner == "bottom_right" then
                    ng = {}
                elseif corner == "bottom_left" then
                    ng = { x = (g.x + g.width) - rg.width }
                elseif corner == "top_left" then
                    ng = { x = (g.x + g.width) - rg.width,
                           y = (g.y + g.height) - rg.height }
                else
                    ng = { y = (g.y + g.height) - rg.height }
                end

                c:geometry({ x = ng.x, y = ng.y })
                return true
            end
        end

        return prev_coords.x == state.x and prev_coords.y == state.y
    end, corner .. "_corner")
end

return function(clay)
    clay.floating = clay.layout {
        name           = "clay.floating",
        body_signature = "context",
        no_gap         = true,
        body           = function(ctx)
            local children = {}
            for i, c in ipairs(ctx.children) do
                local g = c:geometry()
                local bw2 = (c.border_width or 0) * 2
                children[i] = layout.client(c, {
                    x      = g.x - ctx.bounds.x,
                    y      = g.y - ctx.bounds.y,
                    width  = g.width  + bw2,
                    height = g.height + bw2,
                })
            end
            return layout.row { layout.stack { children = children } }
        end,
    }

    -- Floating-specific surface fields the descriptor adapter doesn't
    -- carry: corner resize policy and the interactive resize handler.
    clay.floating.mouse_resize_handler  = mouse_resize_handler
    clay.floating.resize_jump_to_corner = resize_jump_to_corner
end
