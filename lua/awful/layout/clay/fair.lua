-- Fair lays N clients in a sqrt(N) x sqrt(N) grid (rounded). Two
-- orientations: vertical (rows of clients) and horizontal (columns of
-- clients). Both use the modern descriptor shape; orientation is
-- captured in closure since it's a structural choice that doesn't fit
-- bindings or slots.

local math   = math
local layout = require("somewm.layout")

return function(clay)
    local function fair_build(orientation)
        return function(ctx)
            local clients = ctx.children
            local n       = #clients
            if n == 1 then
                return layout.row { layout.client(clients[1]) }
            end

            local rows, cols
            if n == 2 then
                rows, cols = 1, 2
            else
                rows = math.ceil(math.sqrt(n))
                cols = math.ceil(n / rows)
            end

            local outer = (orientation == "horizontal") and layout.row or layout.column
            local inner = (orientation == "horizontal") and layout.column or layout.row

            local row_nodes = {}
            for r = 0, rows - 1 do
                local row_clients = {}
                for c = 0, cols - 1 do
                    local idx = c * rows + r + 1
                    if idx <= n then
                        row_clients[#row_clients + 1] = layout.client(clients[idx])
                    end
                end
                if #row_clients > 0 then
                    row_nodes[#row_nodes + 1] = inner(row_clients)
                end
            end
            return outer(row_nodes)
        end
    end

    clay.fair = clay.layout {
        name           = "clay.fair",
        body_signature = "context",
        body           = fair_build("vertical"),
    }
    clay.fair.horizontal = clay.layout {
        name           = "clay.fairh",
        body_signature = "context",
        body           = fair_build("horizontal"),
    }
end
