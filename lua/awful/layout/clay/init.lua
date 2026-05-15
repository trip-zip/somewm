---------------------------------------------------------------------------
-- Tiled-client layouts and screen composition.
--
-- This module owns two screen-mode responsibilities:
--   1. compose_screen(s): position wibars, compute workarea. Runs before
--      every layout cycle, replaces struts.
--   2. layout(name, build_fn, opts): factory for tiled-client layouts.
--      Each preset (tile, fair, max, etc.) calls this with a builder
--      function that returns a tree describing where clients go.
--
-- The declarative tree primitives (row/column/client/clients/percent)
-- are re-exports from `somewm.layout` so this module and presets can
-- continue using the `clay.*` names. The actual implementation now lives
-- at the engine-agnostic layer.
--
-- @module awful.layout.clay
---------------------------------------------------------------------------

local ipairs = ipairs
local capi = { screen = screen }
local layout = require("somewm.layout")
local clay_c = _somewm_clay

local clay = {}

---------------------------------------------------------------------------
-- Screen composition
---------------------------------------------------------------------------

local function collect_wibars(s)
    local drawins = s._clay_drawins
    if not drawins then return nil end

    local top, bottom, left, right = {}, {}, {}, {}
    local has_any = false

    for wb, info in pairs(drawins) do
        has_any = true
        local entry = { wb = wb, size = info.size, clay_gaps = info.clay_gaps }
        if info.position == "top" then
            top[#top + 1] = entry
        elseif info.position == "bottom" then
            bottom[#bottom + 1] = entry
        elseif info.position == "left" then
            left[#left + 1] = entry
        elseif info.position == "right" then
            right[#right + 1] = entry
        end
    end

    if not has_any then return nil end
    return { top = top, bottom = bottom, left = left, right = right }
end

--- Build the screen-level layout tree, solve it, and write screen.workarea.
-- Called before every layout cycle from `awful.layout.arrange`.
function clay.compose_screen(s)
    local wibars = collect_wibars(s)
    local geo = s.geometry
    local t = s.selected_tag
    local gap = (t and t.gap) or 0

    -- Layer-shell exclusive zones reserve screen edges before any wibar.
    -- arrangelayers() in protocols.c populates these on layer-surface commit.
    local lz_top, lz_right, lz_bottom, lz_left = clay_c.layer_exclusive(s)

    local has_lr = wibars and (#wibars.left > 0 or #wibars.right > 0)
    local middle
    if has_lr then
        middle = layout.row {
            grow = true,
            layout.drawins(wibars.left, "width", gap),
            layout.measure { padding = gap, grow = true },
            layout.drawins(wibars.right, "width", gap),
        }
    else
        middle = layout.measure { padding = gap, grow = true }
    end

    local result = layout.solve {
        screen = s,
        source = "compose_screen",
        width = geo.width, height = geo.height,
        offset_x = geo.x, offset_y = geo.y,
        no_apply = true,
        root = layout.column {
            grow = true,
            padding = { lz_top, lz_right, lz_bottom, lz_left },
            layout.drawins(wibars and wibars.top or nil, "height", gap),
            middle,
            layout.drawins(wibars and wibars.bottom or nil, "height", gap),
        },
    }

    if result.workarea then
        clay_c.set_screen_workarea(s,
            result.workarea.x, result.workarea.y,
            result.workarea.width, result.workarea.height)
    end
end

---------------------------------------------------------------------------
-- Tiled-client layout factory
---------------------------------------------------------------------------

-- Walk a tree, setting `gap` on every container that doesn't already
-- have one set. Mirrors the legacy walk_with_gap semantic so nested
-- containers (used by tile/fair/spiral) inherit the tag's useless_gap.
local function propagate_gap(node, gap)
    if node._type == "container" then
        if not node.props.gap then
            node.props.gap = gap
        end
        for _, child in ipairs(node.children) do
            propagate_gap(child, gap)
        end
    end
end

-- Adapter: wrap a layout descriptor as a tag-suit.
--
-- A descriptor is pure data (`somewm.layout.descriptor`); a tag-suit is
-- the `{name, arrange, skip_gap?}` shape `awful.layout.arrange` expects.
-- This adapter bridges the two shapes via two paths:
--
--   * Modern `body_signature == "context"`: body is `function(ctx) -> tree`
--     and may use `layout.props.X` bindings and `children = layout.first_n(...)`
--     slot specs. The adapter calls `layout.subtree` which calls body and
--     then resolves bindings, expands slots, and drops empty containers.
--
--   * Legacy: body is `function(clients, workarea, tag, params) -> tree`
--     and reads tag fields imperatively. The adapter calls body directly.
--     New presets should use the modern shape; this branch exists so the
--     other suit/* presets keep working until each is migrated.
local function tag_suit_from_descriptor(descriptor)
    local suit = {
        name        = descriptor.name,
        skip_gap    = descriptor.skip_gap,
        descriptor  = descriptor,
    }

    function suit.arrange(p)
        local wa = (descriptor.bounds_source == "geometry")
            and p.geometry or p.workarea
        local gap = descriptor.no_gap and 0 or p.useless_gap
        local t = p.tag or capi.screen[p.screen].selected_tag
        if #p.clients == 0 then return end

        local tree
        if descriptor.body_signature == "context" then
            tree = layout.subtree(descriptor, {
                bounds    = wa,
                props     = t,
                children  = p.clients,
                leaf_kind = "client",
                screen    = p.screen,
                params    = p,
            })
        elseif type(descriptor.body) == "function" then
            tree = descriptor.body(p.clients, wa, t, p)
        elseif descriptor.tree then
            tree = descriptor.tree
        end
        if not tree then return end

        -- The factory's outer wrap is the tree itself (when it's a
        -- container) so the tree's direction propagates naturally.
        -- A leaf tree (single client) is wrapped in a row.
        local root
        if tree._type == "container" then
            tree.props.grow = true
            propagate_gap(tree, gap)
            root = tree
        else
            root = layout.row {
                gap = gap,
                grow = true,
                tree,
            }
        end

        layout.solve {
            screen = p.screen,
            source = "preset",
            width = wa.width, height = wa.height,
            offset_x = wa.x, offset_y = wa.y,
            root = root,
        }

        p._clay_managed = true
    end

    return suit
end

--- Build a tag-layout suit from a tree-builder function or descriptor.
--
-- Accepts two shapes for backward compat:
--   * Legacy positional: `clay.layout(name, build_fn, opts)` where opts
--     is `{ skip_gap?, no_gap? }` and build_fn has the legacy 4-arg
--     `(clients, workarea, tag, p) -> tree` signature. All current
--     presets (clay.tile, clay.fair, etc.) use this shape.
--   * Table-arg: `clay.layout { name = ..., body = fn, skip_gap = ... }`
--     forwards directly to `somewm.layout.descriptor`.
--
-- Internally builds a `somewm.layout.descriptor` and wraps it with the
-- tag-suit adapter, exposing the descriptor at `suit.descriptor` so
-- callers that want pure data can extract it.
--
-- @tparam string|table name_or_spec Either the layout name (legacy) or
--   the full descriptor spec (table-arg).
-- @tparam[opt] function build_fn Legacy build_fn (only with positional
--   shape).
-- @tparam[opt] table opts Legacy opts (only with positional shape).
-- @treturn table A `{name, arrange, skip_gap?, descriptor}` suit.
function clay.layout(name_or_spec, build_fn, opts)
    local spec
    if type(name_or_spec) == "string" then
        opts = opts or {}
        spec = {
            name     = name_or_spec,
            body     = build_fn,
            skip_gap = opts.skip_gap,
            no_gap   = opts.no_gap,
        }
    else
        spec = name_or_spec
    end

    return tag_suit_from_descriptor(layout.descriptor(spec))
end

---------------------------------------------------------------------------
-- Load presets
---------------------------------------------------------------------------

require("awful.layout.clay.tile")(clay)
require("awful.layout.clay.fair")(clay)
require("awful.layout.clay.max")(clay)
require("awful.layout.clay.corner")(clay)
require("awful.layout.clay.spiral")(clay)
require("awful.layout.clay.floating")(clay)
require("awful.layout.clay.magnifier")(clay)

return clay

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
