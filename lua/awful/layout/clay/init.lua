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

---------------------------------------------------------------------------
-- Tree builder API
---------------------------------------------------------------------------

local percent_mt = {}

function clay.percent(value)
    return setmetatable({ _percent = value }, percent_mt)
end

local function is_percent(v)
    return type(v) == "table" and getmetatable(v) == percent_mt
end

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

---------------------------------------------------------------------------
-- Internal helpers: walk tree and call C bindings
---------------------------------------------------------------------------

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

local function collect_wibars(s)
    local drawins = s._clay_drawins
    if not drawins then return nil end

    local top, bottom, left, right = {}, {}, {}, {}
    local has_any = false

    for wb, info in pairs(drawins) do
        has_any = true
        local pos = info.position
        local entry = { wb = wb, size = info.size, clay_gaps = info.clay_gaps }
        if pos == "top" then
            top[#top + 1] = entry
        elseif pos == "bottom" then
            bottom[#bottom + 1] = entry
        elseif pos == "left" then
            left[#left + 1] = entry
        elseif pos == "right" then
            right[#right + 1] = entry
        end
    end

    if not has_any then return nil end
    return { top = top, bottom = bottom, left = left, right = right }
end

function clay.compose_screen(s)
    local wibars = collect_wibars(s)

    local geo = s.geometry
    local t = s.selected_tag
    local gap = t and t.gap or 0

    clay_c.begin_layout(s, geo.width, geo.height, {
        offset_x = geo.x,
        offset_y = geo.y,
    })

    clay_c.open_container({ direction = "column", grow = true })

    if wibars then
        local has_lr = #wibars.left > 0 or #wibars.right > 0

        for _, wb in ipairs(wibars.top) do
            if wb.clay_gaps then
                clay_c.open_container({
                    padding = { gap, gap, gap, gap },
                    width_percent = 100,
                    grow = false,
                })
                clay_c.drawin_element(wb.wb.drawin, { height_fixed = wb.size })
                clay_c.close_container()
            else
                clay_c.drawin_element(wb.wb.drawin, { height_fixed = wb.size })
            end
        end

        if has_lr then
            clay_c.open_container({ direction = "row", grow = true })

            for _, wb in ipairs(wibars.left) do
                if wb.clay_gaps then
                    clay_c.open_container({
                        padding = { gap, gap, gap, gap },
                        height_percent = 100,
                        grow = false,
                    })
                    clay_c.drawin_element(wb.wb.drawin, { width_fixed = wb.size })
                    clay_c.close_container()
                else
                    clay_c.drawin_element(wb.wb.drawin, { width_fixed = wb.size })
                end
            end

            clay_c.workarea_element({
                padding = { gap, gap, gap, gap },
                grow = true,
            })

            for _, wb in ipairs(wibars.right) do
                if wb.clay_gaps then
                    clay_c.open_container({
                        padding = { gap, gap, gap, gap },
                        height_percent = 100,
                        grow = false,
                    })
                    clay_c.drawin_element(wb.wb.drawin, { width_fixed = wb.size })
                    clay_c.close_container()
                else
                    clay_c.drawin_element(wb.wb.drawin, { width_fixed = wb.size })
                end
            end

            clay_c.close_container()
        else
            clay_c.workarea_element({
                padding = { gap, gap, gap, gap },
                grow = true,
            })
        end

        for _, wb in ipairs(wibars.bottom) do
            if wb.clay_gaps then
                clay_c.open_container({
                    padding = { gap, gap, gap, gap },
                    width_percent = 100,
                    grow = false,
                })
                clay_c.drawin_element(wb.wb.drawin, { height_fixed = wb.size })
                clay_c.close_container()
            else
                clay_c.drawin_element(wb.wb.drawin, { height_fixed = wb.size })
            end
        end
    else
        clay_c.workarea_element({
            padding = { gap, gap, gap, gap },
            grow = true,
        })
    end

    clay_c.close_container()

    local workarea = clay_c.end_layout()

    if workarea then
        clay_c.set_screen_workarea(s,
            workarea.x, workarea.y, workarea.width, workarea.height)
    end
end

---------------------------------------------------------------------------
-- Client tiling: layout factory
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

        local root_dir = (tree.props and tree.props.direction) or "row"
        clay_c.open_container({
            direction = root_dir,
            gap = gap,
            grow = true,
        })
        emit_client_tree(tree, gap)
        clay_c.close_container()

        clay_c.end_layout()
        p._clay_managed = true
    end

    return suit
end

---------------------------------------------------------------------------
-- Load presets
---------------------------------------------------------------------------

require("awful.layout.clay.tile")(clay)
require("awful.layout.clay.fair")(clay)
require("awful.layout.clay.max")(clay)
require("awful.layout.clay.corner")(clay)

return clay

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
