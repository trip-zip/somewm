---------------------------------------------------------------------------
-- Declarative layout using the Clay flexbox engine.
--
-- Layouts are described as trees of rows, columns, and client elements.
-- Clay (C library) computes all positions in a single pass. Results are
-- applied directly by C in the frame refresh cycle (Step 1.75).
--
-- Gap handling is native to Clay: root container padding creates edge
-- margins, container childGap creates spacing between siblings. This
-- produces consistent gaps everywhere (edge = between = gap).
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
            -- Flatten nested arrays (tables without _type, e.g. from clay.clients)
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
        -- Inject gap into every container so spacing is consistent
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

-- Create an awful.layout-compatible suit from a tree-building function

function clay.layout(name, build_fn, opts)
    opts = opts or {}
    local suit = {}
    suit.name = name

    if opts.skip_gap then
        suit.skip_gap = opts.skip_gap
    end

    function suit.arrange(p)
        local wa = p.workarea
        local gap = p.useless_gap
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
        -- Walk tree contents (skip the root node itself since we opened it above)
        if tree._type == "container" then
            for _, child in ipairs(tree.children) do
                walk_with_gap(child, gap)
            end
        elseif tree._type == "client" then
            -- Single client returned directly
            local cfg = make_config(tree.props, "row")
            clay_c.client_element(tree.client, cfg)
        end
        clay_c.close_container()

        clay_c.end_layout()

        -- Signal the framework to skip its gap/border/c:geometry() loop.
        -- Geometry is applied by C in clay_apply_all() at Step 1.75.
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

        -- Column-first fill order (matches awful.layout.suit.fair)
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

return clay

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
