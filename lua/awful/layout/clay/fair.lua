local math = math

return function(clay)
    local function fair_build(orientation)
        return function(clients, wa, t)
            local n = #clients
            if n == 1 then return clay.client(clients[1]) end

            local rows, cols
            if n == 2 then
                rows, cols = 1, 2
            else
                rows = math.ceil(math.sqrt(n))
                cols = math.ceil(n / rows)
            end

            local outer = (orientation == "horizontal") and clay.row or clay.column
            local inner = (orientation == "horizontal") and clay.column or clay.row

            local row_nodes = {}
            for r = 0, rows - 1 do
                local row_clients = {}
                for c = 0, cols - 1 do
                    local idx = c * rows + r + 1
                    if idx <= n then
                        row_clients[#row_clients + 1] = clay.client(clients[idx])
                    end
                end
                if #row_clients > 0 then
                    row_nodes[#row_nodes + 1] = inner(row_clients)
                end
            end
            return outer(row_nodes)
        end
    end

    clay.fair = clay.layout("clay.fair", fair_build("vertical"))
    clay.fair.horizontal = clay.layout("clay.fairh", fair_build("horizontal"))
end
