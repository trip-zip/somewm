-- Corner layouts (NW, NE, SW, SE): a master client at one corner with
-- master_width_factor share of width AND height; remaining clients fill
-- a row + column wrapping the master. Whether the row or column gets
-- the "privileged" (corner-aligned) slot flips on master_count parity,
-- so the body picks the structural variant imperatively. mwfact and the
-- parity gate read through ctx.props as bindings; child distribution is
-- index-based on ctx.children rather than slot specs.

local layout = require("somewm.layout")

return function(clay)
    local function corner_skip_gap(nclients, t)
        return nclients == 1 and t.master_fill_policy == "expand"
    end

    local function corner_build(orientation)
        return function(ctx)
            local clients = ctx.children
            if #clients == 1 then
                return layout.row { layout.client(clients[1]) }
            end

            local mwfact         = ctx.props.master_width_factor
            local row_privileged = (ctx.props.master_count % 2 == 0)

            local master_node = layout.client(clients[1], {
                width  = layout.percent(mwfact * 100),
                height = layout.percent(mwfact * 100),
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
                layout.column { layout.clients(col_clients) } or nil
            local row_node = #row_clients > 0 and
                layout.row { layout.clients(row_clients) } or nil

            local is_north = orientation:match("N")
            local is_west  = orientation:match("W")

            local master_side
            if col_node then
                if row_privileged then
                    col_node.props.height = layout.percent(mwfact * 100)
                end
                if is_west then
                    master_side = layout.row { master_node, col_node }
                else
                    master_side = layout.row { col_node, master_node }
                end
            else
                master_side = master_node
            end

            if row_node and not row_privileged then
                row_node.props.width = layout.percent(mwfact * 100)
            end

            if is_north then
                if row_node then
                    return layout.column { master_side, row_node }
                else
                    return layout.row { master_side }
                end
            else
                if row_node then
                    return layout.column { row_node, master_side }
                else
                    return layout.row { master_side }
                end
            end
        end
    end

    clay.corner = {
        skip_gap       = corner_skip_gap,
        row_privileged = false,
    }
    clay.corner.nw = clay.layout {
        name           = "clay.cornernw",
        body_signature = "context",
        skip_gap       = corner_skip_gap,
        body           = corner_build("NW"),
    }
    clay.corner.ne = clay.layout {
        name           = "clay.cornerne",
        body_signature = "context",
        skip_gap       = corner_skip_gap,
        body           = corner_build("NE"),
    }
    clay.corner.sw = clay.layout {
        name           = "clay.cornersw",
        body_signature = "context",
        skip_gap       = corner_skip_gap,
        body           = corner_build("SW"),
    }
    clay.corner.se = clay.layout {
        name           = "clay.cornerse",
        body_signature = "context",
        skip_gap       = corner_skip_gap,
        body           = corner_build("SE"),
    }
end
