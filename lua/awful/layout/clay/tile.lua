local math = math

return function(clay)
    local function tile_skip_gap(nclients, t)
        return nclients == 1 and t.master_fill_policy == "expand"
    end

    local function tile_build(orientation)
        return function(clients, wa, t)
            local nmaster = math.min(t.master_count, #clients)
            local mwfact = t.master_width_factor

            if #clients == 1 then
                return clay.client(clients[1])
            end

            local master = clay.slice(clients, 1, nmaster)
            local slaves = clay.slice(clients, nmaster + 1)

            if nmaster == 0 then
                return clay.column { clay.clients(slaves) }
            end
            if #slaves == 0 then
                return clay.column { clay.clients(master) }
            end

            local is_horiz = (orientation == "right" or orientation == "left")
            local outer = is_horiz and clay.row or clay.column
            local inner = is_horiz and clay.column or clay.row
            local size_key = is_horiz and "width" or "height"

            local master_pane = inner {
                [size_key] = clay.percent(mwfact * 100),
                clay.clients(master),
            }
            local slave_pane = inner {
                clay.clients(slaves),
            }

            if orientation == "right" or orientation == "top" then
                return outer { master_pane, slave_pane }
            else
                return outer { slave_pane, master_pane }
            end
        end
    end

    clay.tile = clay.layout("clay.tile", tile_build("right"),
        { skip_gap = tile_skip_gap })
    clay.tile.left = clay.layout("clay.tileleft", tile_build("left"),
        { skip_gap = tile_skip_gap })
    clay.tile.top = clay.layout("clay.tiletop", tile_build("top"),
        { skip_gap = tile_skip_gap })
    clay.tile.bottom = clay.layout("clay.tilebottom", tile_build("bottom"),
        { skip_gap = tile_skip_gap })
end
