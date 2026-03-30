---------------------------------------------------------------------------
-- Declarative layout using the Clay flexbox engine.
--
-- Two-level system:
-- 1. Screen composition (compose_screen): positions wibars, computes workarea.
--    Runs before every layout cycle. Replaces struts.
-- 2. Client tiling (suit.arrange): positions clients within the workarea.
--    Uses Clay for native presets, traditional suits also work.
--
-- @module awful.layout.clay
---------------------------------------------------------------------------

local math = math
local capi = { screen = screen }
local clay_c = _somewm_clay

local clay = {}

-- Sizing helpers

local percent_mt = {}

function clay.percent(value)
    return setmetatable({ _percent = value }, percent_mt)
end

local function is_percent(v)
    return type(v) == "table" and getmetatable(v) == percent_mt
end

-- Tree builders

local function collect_children(args)
    local props = {}
    local children = {}
    for k, v in pairs(args) do
        if type(k) == "number" then
            if type(v) == "table" and not v._type then
                for _, child in ipairs(v) do
                    children[#children + 1] = child
                end
            else
                children[#children + 1] = v
            end
        else
            props[k] = v
        end
    end
    return props, children
end

function clay.row(args)
    local props, children = collect_children(args)
    props.direction = "row"
    return { _type = "container", props = props, children = children }
end

function clay.column(args)
    local props, children = collect_children(args)
    props.direction = "column"
    return { _type = "container", props = props, children = children }
end

function clay.client(c, props)
    return { _type = "client", client = c, props = props or {} }
end

function clay.clients(list, props)
    local result = {}
    for _, c in ipairs(list) do
        result[#result + 1] = clay.client(c, props)
    end
    return result
end

function clay.slice(list, from, to)
    local result = {}
    for i = from, (to or #list) do
        result[#result + 1] = list[i]
    end
    return result
end

-- Walk tree and call C bindings, injecting gap into every container

local function make_config(props, direction)
    local cfg = { direction = direction }
    if props.gap then
        cfg.gap = props.gap
    end
    if props.grow ~= nil then
        cfg.grow = props.grow
    end
    if props.width then
        if is_percent(props.width) then
            cfg.width_percent = props.width._percent
        elseif type(props.width) == "number" then
            cfg.width_fixed = props.width
        end
    end
    if props.height then
        if is_percent(props.height) then
            cfg.height_percent = props.height._percent
        elseif type(props.height) == "number" then
            cfg.height_fixed = props.height
        end
    end
    if props.padding then
        cfg.padding = props.padding
    end
    return cfg
end

local function walk_with_gap(node, gap)
    if not node then return end

    if node._type == "client" then
        local cfg = make_config(node.props, "row")
        clay_c.client_element(node.client, cfg)
    elseif node._type == "container" then
        if gap > 0 and not node.props.gap then
            node.props.gap = gap
        end
        local cfg = make_config(node.props, node.props.direction)
        clay_c.open_container(cfg)
        for _, child in ipairs(node.children) do
            walk_with_gap(child, gap)
        end
        clay_c.close_container()
    end
end

-- Emit the client layout tree contents into the current Clay context
local function emit_client_tree(tree, gap)
    if tree._type == "container" then
        for _, child in ipairs(tree.children) do
            walk_with_gap(child, gap)
        end
    elseif tree._type == "client" then
        local cfg = make_config(tree.props, "row")
        clay_c.client_element(tree.client, cfg)
    end
end

---------------------------------------------------------------------------
-- Screen composition: positions wibars, computes workarea.
-- Called before every layout cycle. Replaces struts entirely.
---------------------------------------------------------------------------

-- Collect registered wibars from the screen by position
local function collect_wibars(s)
    local drawins = s._clay_drawins
    if not drawins then return nil end

    local top, bottom, left, right = {}, {}, {}, {}
    local has_any = false

    for wb, info in pairs(drawins) do
        has_any = true
        local pos = info.position
        if pos == "top" then
            top[#top + 1] = { wb = wb, size = info.size }
        elseif pos == "bottom" then
            bottom[#bottom + 1] = { wb = wb, size = info.size }
        elseif pos == "left" then
            left[#left + 1] = { wb = wb, size = info.size }
        elseif pos == "right" then
            right[#right + 1] = { wb = wb, size = info.size }
        end
    end

    if not has_any then return nil end
    return { top = top, bottom = bottom, left = left, right = right }
end

--- Compose the screen: position wibars and compute workarea via Clay.
-- This runs before layout.parameters() so that screen.workarea reflects
-- Clay's computation. Replaces the strut-based workarea system.
-- @tparam screen s The screen to compose.
function clay.compose_screen(s)
    local wibars = collect_wibars(s)
    if not wibars then return end

    local geo = s.geometry
    local has_lr = #wibars.left > 0 or #wibars.right > 0

    clay_c.begin_layout(s, geo.width, geo.height, {
        offset_x = geo.x,
        offset_y = geo.y,
    })

    -- Screen tree: column { top wibars, middle, bottom wibars }
    clay_c.open_container({ direction = "column", grow = true })

    -- Top wibars
    for _, wb in ipairs(wibars.top) do
        clay_c.drawin_element(wb.wb.drawin, { height_fixed = wb.size })
    end

    if has_lr then
        -- Middle row: { left wibars, workarea, right wibars }
        clay_c.open_container({ direction = "row", grow = true })

        for _, wb in ipairs(wibars.left) do
            clay_c.drawin_element(wb.wb.drawin, { width_fixed = wb.size })
        end

        -- Workarea marker: grows to fill remaining space
        clay_c.workarea_element({ grow = true })

        for _, wb in ipairs(wibars.right) do
            clay_c.drawin_element(wb.wb.drawin, { width_fixed = wb.size })
        end

        clay_c.close_container() -- middle row
    else
        -- No left/right wibars: workarea directly in column
        clay_c.workarea_element({ grow = true })
    end

    -- Bottom wibars
    for _, wb in ipairs(wibars.bottom) do
        clay_c.drawin_element(wb.wb.drawin, { height_fixed = wb.size })
    end

    clay_c.close_container() -- outer column

    -- end_layout returns workarea bounds if a workarea_element was present
    local workarea = clay_c.end_layout()

    if workarea then
        -- Update screen.workarea via C so layout.parameters() reads Clay's bounds
        clay_c.set_screen_workarea(s,
            workarea.x, workarea.y, workarea.width, workarea.height)
    end
end

---------------------------------------------------------------------------
-- Client tiling: positions clients within the workarea.
---------------------------------------------------------------------------

function clay.layout(name, build_fn, opts)
    opts = opts or {}
    local suit = {}
    suit.name = name

    if opts.skip_gap then
        suit.skip_gap = opts.skip_gap
    end

    function suit.arrange(p)
        local wa = p.workarea
        local gap = opts.no_gap and 0 or p.useless_gap
        local t = p.tag or capi.screen[p.screen].selected_tag
        if #p.clients == 0 then return end

        local tree = build_fn(p.clients, wa, t, p)
        if not tree then return end

        clay_c.begin_layout(p.screen, wa.width, wa.height, {
            offset_x = wa.x,
            offset_y = wa.y,
        })

        -- Root container: padding creates edge margins, childGap between children
        local root_dir = (tree.props and tree.props.direction) or "row"
        clay_c.open_container({
            direction = root_dir,
            gap = gap,
            padding = { gap, gap, gap, gap },
            grow = true,
        })
        emit_client_tree(tree, gap)
        clay_c.close_container()

        clay_c.end_layout()
        p._clay_managed = true
    end

    return suit
end

-- Built-in tile preset

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

-- Built-in fair preset

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

-- Built-in max preset

local function max_build(clients, wa, t)
    -- Only the top client is visible (others are behind it in z-order).
    -- Return just the first client filling the entire space.
    return clay.client(clients[1])
end

clay.max = clay.layout("clay.max", max_build, {
    skip_gap = function() return true end,
    no_gap = true,
})

-- Built-in corner presets (nw, ne, sw, se)
--
-- Master in one corner sized by mwfact in both dimensions.
-- Remaining clients alternate between a column along one edge
-- and a row along the perpendicular edge.
-- master_count % 2 determines which group (row or column) is "privileged"
-- (gets more clients and spans the full edge).

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

        -- Split remaining clients: even indices -> group A, odd -> group B
        local group_a, group_b = {}, {}
        for i = 2, #clients do
            if i % 2 == 0 then
                group_a[#group_a + 1] = clients[i]
            else
                group_b[#group_b + 1] = clients[i]
            end
        end

        -- Privileged group gets more clients (ceil of remaining/2)
        local col_clients, row_clients
        if row_privileged then
            row_clients = group_a  -- privileged: spans full width
            col_clients = group_b  -- unprivileged: spans master height only
        else
            col_clients = group_a  -- privileged: spans full height
            row_clients = group_b  -- unprivileged: spans master width only
        end

        -- Build the column of slaves (along vertical edge opposite master)
        local col_node = #col_clients > 0 and
            clay.column { clay.clients(col_clients) } or nil

        -- Build the row of slaves (along horizontal edge opposite master)
        local row_node = #row_clients > 0 and
            clay.row { clay.clients(row_clients) } or nil

        -- Assemble the tree based on orientation and privilege
        -- The structure is always:
        --   column {
        --     top_row (master row or slave row)
        --     bottom_row (slave row or master row)
        --   }
        -- where top_row = row { master_side, column_side }

        local is_north = orientation:match("N")
        local is_west = orientation:match("W")

        -- Master row: master + column slaves (or just master)
        local master_side
        if col_node then
            if row_privileged then
                -- Column is unprivileged: only spans master height
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

        -- Slave row spans full width when privileged, master width when not
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

return clay

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
