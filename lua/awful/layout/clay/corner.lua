return function(clay)
    local function corner_skip_gap(nclients, t)
        return nclients == 1 and t.master_fill_policy == "expand"
    end

    local function corner_build(orientation)
        return function(clients, wa, t)
            if #clients == 1 then
                return clay.client(clients[1])
            end

            local mwfact = t.master_width_factor
            local row_privileged = (t.master_count % 2 == 0)

            local master_node = clay.client(clients[1], {
                width = clay.percent(mwfact * 100),
                height = clay.percent(mwfact * 100),
            })

            local group_a, group_b = {}, {}
            for i = 2, #clients do
                if i % 2 == 0 then
                    group_a[#group_a + 1] = clients[i]
                else
                    group_b[#group_b + 1] = clients[i]
                end
            end

            local col_clients, row_clients
            if row_privileged then
                row_clients = group_a
                col_clients = group_b
            else
                col_clients = group_a
                row_clients = group_b
            end

            local col_node = #col_clients > 0 and
                clay.column { clay.clients(col_clients) } or nil
            local row_node = #row_clients > 0 and
                clay.row { clay.clients(row_clients) } or nil

            local is_north = orientation:match("N")
            local is_west = orientation:match("W")

            local master_side
            if col_node then
                if row_privileged then
                    col_node.props.height = clay.percent(mwfact * 100)
                end
                if is_west then
                    master_side = clay.row { master_node, col_node }
                else
                    master_side = clay.row { col_node, master_node }
                end
            else
                master_side = master_node
            end

            if row_node and not row_privileged then
                row_node.props.width = clay.percent(mwfact * 100)
            end

            if is_north then
                if row_node then
                    return clay.column { master_side, row_node }
                else
                    return master_side
                end
            else
                if row_node then
                    return clay.column { row_node, master_side }
                else
                    return master_side
                end
            end
        end
    end

    clay.corner = {}
    clay.corner.nw = clay.layout("clay.cornernw", corner_build("NW"),
        { skip_gap = corner_skip_gap })
    clay.corner.ne = clay.layout("clay.cornerne", corner_build("NE"),
        { skip_gap = corner_skip_gap })
    clay.corner.sw = clay.layout("clay.cornersw", corner_build("SW"),
        { skip_gap = corner_skip_gap })
    clay.corner.se = clay.layout("clay.cornerse", corner_build("SE"),
        { skip_gap = corner_skip_gap })
end
