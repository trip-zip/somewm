---------------------------------------------------------------------------
-- Declarative composition API for spatial layout.
--
-- Builders return plain tables describing a tree; the solver walks the
-- tree, calls the engine, and returns rect placements. The API is engine-
-- agnostic: nothing in the public surface names the underlying solver
-- (currently Clay), so an engine swap touches only the implementation.
-- The substrate has no dependency on wibox and is safe to use from any
-- caller (wibox layouts, awful presets, future plugins).
--
-- Use `somewm.layout` from anywhere that needs to position widgets,
-- clients, drawins, or measured rects:
--
--    local layout = require("somewm.layout")
--    local result = layout.solve {
--        width = w, height = h,
--        root = layout.row {
--            gap = 5,
--            layout.widgets(self._private.widgets, { grow = true }),
--        },
--    }
--    -- result.placements is { {widget, x, y, width, height}, ... }
--    -- wibox callers wrap with wibox.widget.base.place_rects.
--
-- @module somewm.layout
---------------------------------------------------------------------------

local math = math
local ipairs = ipairs
local pairs = pairs
local type = type
local setmetatable = setmetatable
local getmetatable = getmetatable

local clay_c = _somewm_clay

local layout = {}

---------------------------------------------------------------------------
-- Sizing sentinel for percentage values
---------------------------------------------------------------------------

local percent_mt = {}

--- Wrap a number as a percentage sizing value.
-- Use as `width = layout.percent(60)` to mean "60% of the parent".
-- @tparam number value Percentage in 0-100.
-- @treturn table Sentinel consumed by the solver.
function layout.percent(value)
    return setmetatable({ _percent = value }, percent_mt)
end

local function is_percent(v)
    return type(v) == "table" and getmetatable(v) == percent_mt
end

---------------------------------------------------------------------------
-- Bindings: lazy values resolved at solve time against context.props
---------------------------------------------------------------------------
--
-- A binding is a deferred read from the runtime context. Inside a layout
-- descriptor you write `width = layout.props.master_factor * 100` to mean
-- "look up `master_factor` on the context's prop bag at solve time and
-- multiply by 100." The binding builds a small expression tree as you
-- compose it; `subtree` walks the layout tree at solve time and replaces
-- each binding with its resolved value.

local binding_mt = {}
binding_mt.__index = binding_mt

local function is_binding(v)
    return type(v) == "table" and rawget(v, "_is_binding") == true
end

local function make_binding(resolve_fn)
    return setmetatable({ _is_binding = true, _resolve = resolve_fn }, binding_mt)
end

function binding_mt:resolve(ctx)
    return self._resolve(ctx)
end

-- Resolve `v` if it's a binding, else return as-is.
local function eval_value(v, ctx)
    if is_binding(v) then return v:resolve(ctx) end
    return v
end

-- Build a binary-op metamethod that defers evaluation.
local function binop(op)
    return function(a, b)
        return make_binding(function(ctx)
            return op(eval_value(a, ctx), eval_value(b, ctx))
        end)
    end
end

binding_mt.__add = binop(function(a, b) return a + b end)
binding_mt.__sub = binop(function(a, b) return a - b end)
binding_mt.__mul = binop(function(a, b) return a * b end)
binding_mt.__div = binop(function(a, b) return a / b end)
binding_mt.__mod = binop(function(a, b) return a % b end)
binding_mt.__pow = binop(function(a, b) return a ^ b end)
binding_mt.__unm = function(a)
    return make_binding(function(ctx) return -eval_value(a, ctx) end)
end
-- Comparison metamethods produce boolean-resolving bindings. Exposed
-- in case a future author wants conditional sizing inside a descriptor.
binding_mt.__eq = binop(function(a, b) return a == b end)
binding_mt.__lt = binop(function(a, b) return a < b end)
binding_mt.__le = binop(function(a, b) return a <= b end)

--- Magic table: `layout.props.NAME` is a binding that resolves to
-- `context.props.NAME` at solve time. Chain with arithmetic metamethods
-- to build expressions: `layout.props.master_factor * 100`.
local props_mt = {}
function props_mt:__index(key)
    return make_binding(function(ctx)
        return ctx and ctx.props and ctx.props[key]
    end)
end

layout.props = setmetatable({}, props_mt)

--- Magic table: `layout.mouse.x` and `layout.mouse.y` are bindings that
-- resolve to the current mouse position at solve time via the
-- compositor's `mouse.coords()` API. Used for placements anchored to
-- the cursor (popup-near-mouse, drag-resize hints). When `_G.mouse` is
-- absent (busted unit tests with no shim) the bindings resolve to 0
-- so the placement falls back to the parent's origin without erroring.
local mouse_mt = {}
function mouse_mt:__index(key)
    return make_binding(function(_ctx)
        local m = _G.mouse
        if not m then return 0 end
        local coords = m.coords and m.coords() or m
        return (coords and coords[key]) or 0
    end)
end

layout.mouse = setmetatable({}, mouse_mt)

-- Walk a value tree replacing bindings with resolved values. Recurses
-- into nested tables (so bindings inside `layout.percent`, padding arrays,
-- and align structs are reached). Mutates in place.
local function resolve_prop(v, ctx)
    if type(v) ~= "table" then return v end
    if rawget(v, "_is_binding") then
        return v:resolve(ctx)
    end
    for k, vv in pairs(v) do
        v[k] = resolve_prop(vv, ctx)
    end
    return v
end

-- Walk the tree resolving every node's props. Internal helper for subtree.
local function resolve_bindings(node, ctx)
    if node.props then
        for k, v in pairs(node.props) do
            node.props[k] = resolve_prop(v, ctx)
        end
    end
    if node._type == "container" and node.children then
        for _, child in ipairs(node.children) do
            resolve_bindings(child, ctx)
        end
    end
    return node
end

---------------------------------------------------------------------------
-- Slot specs: declare children at descriptor time, expand at solve time
---------------------------------------------------------------------------
--
-- A slot is a placeholder inside a container that says "fill in children
-- from `context.children` here". Authors write
--    children = layout.first_n(layout.props.master_count)
-- instead of iterating context.children imperatively in a body function.
--
-- Slot args may be bindings; the expand pass resolves them against
-- context.props before slicing context.children.

local slot_mt = {}
slot_mt.__index = slot_mt

local function is_slot(v)
    return type(v) == "table" and rawget(v, "_is_slot") == true
end

local function make_slot(kind, fn)
    return setmetatable(
        { _is_slot = true, _kind = kind, _fn = fn }, slot_mt)
end

function slot_mt:expand(ctx)
    return self._fn(ctx)
end

local function children_of(ctx)
    return (ctx and ctx.children) or {}
end

--- Slot: every child from `context.children`.
function layout.all()
    return make_slot("all", function(ctx)
        local src = children_of(ctx)
        local out = {}
        for i = 1, #src do out[i] = src[i] end
        return out
    end)
end

--- Slot: the first `n` children. Clamped to available; n<=0 -> empty.
-- @tparam number|binding n
function layout.first_n(n)
    return make_slot("first_n", function(ctx)
        local count = eval_value(n, ctx) or 0
        if count < 0 then count = 0 end
        local src = children_of(ctx)
        if count > #src then count = #src end
        local out = {}
        for i = 1, count do out[i] = src[i] end
        return out
    end)
end

--- Slot: every child after the first `n`. Clamped to available.
-- @tparam number|binding n
function layout.rest_after(n)
    return make_slot("rest_after", function(ctx)
        local skip = eval_value(n, ctx) or 0
        if skip < 0 then skip = 0 end
        local src  = children_of(ctx)
        local out  = {}
        for i = skip + 1, #src do
            out[#out + 1] = src[i]
        end
        return out
    end)
end

-- Wrap a raw item from context.children as a leaf based on context.leaf_kind.
-- Pre-wrapped layout nodes (with `_type`) pass through unchanged.
local function leaf_for(item, leaf_kind)
    if type(item) == "table" and rawget(item, "_type") then
        return item
    end
    if leaf_kind == "widget" then
        return layout.widget(item)
    elseif leaf_kind == "client" then
        return layout.client(item)
    elseif leaf_kind == "drawin" then
        return layout.drawin(item)
    end
    error("somewm.layout: cannot expand slot without context.leaf_kind "
          .. "(got " .. tostring(leaf_kind) .. ")")
end

-- Walk the tree expanding `_slot` markers into leaves drawn from
-- context.children. Mutates in place. Recurses into all containers so
-- nested slots all get expanded in one pass.
local function expand_slots(node, ctx)
    if node._type ~= "container" then return node end
    if node._slot then
        local items = node._slot:expand(ctx)
        for _, item in ipairs(items) do
            node.children[#node.children + 1] =
                leaf_for(item, ctx and ctx.leaf_kind)
        end
        node._slot = nil
    end
    for _, child in ipairs(node.children) do
        expand_slots(child, ctx)
    end
    return node
end

-- Empty containers with explicit sizing (grow / grow_max / width / height)
-- are kept: they're intentional spacers (e.g., `layout.row { grow = true }`
-- in `wibox.layout.align` to anchor the third slot at the far edge).
-- Empty + sizing-less containers are incidental and get dropped.
local function has_explicit_size(node)
    local p = node.props
    if not p then return false end
    return p.grow == true
        or p.grow_max ~= nil
        or p.width   ~= nil
        or p.height  ~= nil
end

-- Walk bottom-up dropping containers whose children all collapsed away.
-- The root container is preserved even if empty (caller flags via is_root)
-- so callers always get a tree back. See `has_explicit_size` for the
-- intentional-spacer carve-out.
local function drop_empty_containers(node, is_root)
    if node._type ~= "container" then return node end
    local kept = {}
    for _, child in ipairs(node.children) do
        local resolved = drop_empty_containers(child, false)
        if resolved ~= nil then
            kept[#kept + 1] = resolved
        end
    end
    node.children = kept
    if #kept == 0 and not is_root and not has_explicit_size(node) then
        return nil
    end
    return node
end

---------------------------------------------------------------------------
-- Internal: fold positional + named keys from a builder's args table.
-- Nested arrays (no _type) are flattened, so helpers like layout.widgets
-- can return a list that gets transparently spread into the parent. The
-- `children` named key is special: a slot spec lands on `node._slot` for
-- expansion at solve time; an array extends the positional children.
---------------------------------------------------------------------------

local function collect_children(args)
    local props, children, slot = {}, {}, nil
    for k, v in pairs(args) do
        if type(k) == "number" then
            if type(v) == "table" and not v._type then
                for _, child in ipairs(v) do
                    children[#children + 1] = child
                end
            else
                children[#children + 1] = v
            end
        elseif k == "children" then
            if is_slot(v) then
                slot = v
            elseif type(v) == "table" then
                for _, child in ipairs(v) do
                    children[#children + 1] = child
                end
            else
                error("somewm.layout: `children` must be a slot or array, "
                      .. "got " .. type(v))
            end
        else
            props[k] = v
        end
    end
    return props, children, slot
end

---------------------------------------------------------------------------
-- Container builders
---------------------------------------------------------------------------

--- Horizontal container (left-to-right flow).
-- Children may be passed positionally; named keys become props. Pass
-- `children = layout.first_n(N)` (or any slot spec) to fill the
-- container from `context.children` at solve time; positional children
-- come first, then slot-expanded leaves are appended.
-- @tparam table args Mixed positional children + named props (gap, padding,
--   width, height, grow, etc.).
function layout.row(args)
    local props, children, slot = collect_children(args)
    props.direction = "row"
    return {
        _type    = "container",
        props    = props,
        children = children,
        _slot    = slot,
    }
end

--- Vertical container (top-to-bottom flow).
function layout.column(args)
    local props, children, slot = collect_children(args)
    props.direction = "column"
    return {
        _type    = "container",
        props    = props,
        children = children,
        _slot    = slot,
    }
end

--- Stack container: children attach to the parent rect as floating
-- elements, ignoring flow. By default each child fills the parent
-- (overlap mode, used by `clay.max`); pass `{ x, y, width, height }`
-- props on individual children for absolute positioning (used by
-- `wibox.layout.{stack, manual, grid}`, `clay.floating`, etc.).
--
-- The container itself participates in flow normally; only its direct
-- children are floating-attached. Nested stacks attach floating to
-- their immediate stack parent.
function layout.stack(args)
    local props, children, slot = collect_children(args)
    -- Direction is irrelevant for stack (no flow), but Clay's layout
    -- config still wants one set; `row` is the harmless default.
    props.direction = "row"
    props._stack    = true
    return {
        _type    = "container",
        props    = props,
        children = children,
        _slot    = slot,
    }
end

---------------------------------------------------------------------------
-- Leaf builders
---------------------------------------------------------------------------

--- Widget leaf for widget-mode passes.
function layout.widget(w, props)
    return { _type = "widget", widget = w, props = props or {} }
end

--- Convenience: turn a widget list into an array of widget leaves with
-- shared props. Used inside container args; gets flattened automatically.
function layout.widgets(list, props)
    local result = {}
    props = props or {}
    for _, w in ipairs(list) do
        result[#result + 1] = layout.widget(w, props)
    end
    return result
end

--- Client leaf for screen-mode passes (tiled-client layout).
function layout.client(c, props)
    return { _type = "client", client = c, props = props or {} }
end

function layout.clients(list, props)
    local result = {}
    props = props or {}
    for _, c in ipairs(list) do
        result[#result + 1] = layout.client(c, props)
    end
    return result
end

--- Drawin leaf (used by compose_screen for wibars).
function layout.drawin(d, props)
    return { _type = "drawin", drawin = d, props = props or {} }
end

--- Convenience: turn a list of `{wb, size, clay_gaps}` entries into
-- drawin leaves sized along `axis` ("width" or "height"). When an entry
-- has `clay_gaps = true` and `gap > 0`, the drawin is wrapped in a
-- container that pads by `gap` and fills the perpendicular axis.
function layout.drawins(list, axis, gap)
    local result = {}
    if not list then return result end

    for _, entry in ipairs(list) do
        local size_props = {}
        size_props[axis] = entry.size
        local node = layout.drawin(entry.wb.drawin, size_props)

        if entry.clay_gaps and gap and gap > 0 then
            local wrap = { padding = gap, node }
            if axis == "height" then
                wrap.width = layout.percent(100)
            else
                wrap.height = layout.percent(100)
            end
            wrap.grow = false
            node = layout.row(wrap)
        end

        result[#result + 1] = node
    end
    return result
end

--- Measured-rect marker leaf. The solver returns the bounds of this
-- element as `result.workarea` so callers can read where the measured
-- rect ended up. Used by `compose_screen` (the rect IS the screen
-- workarea, written to `screen.workarea`) and by `placement.solve` (the
-- rect is the anchored target rect for absolute-coord placement). The
-- two callers share one primitive because both want "place a rect inside
-- a parent and tell me where it landed."
function layout.measure(props)
    return { _type = "workarea", props = props or {} }
end

---------------------------------------------------------------------------
-- Internal: translate node props into the engine's flat config table.
---------------------------------------------------------------------------

local function make_config(props)
    local cfg = {}

    if props.direction then
        cfg.direction = props.direction
    end
    if props.gap then
        cfg.gap = props.gap
    end
    if props.grow ~= nil then
        cfg.grow = props.grow
    end
    if props.grow_max then
        cfg.grow_max = props.grow_max
    end

    if props.width ~= nil then
        if is_percent(props.width) then
            cfg.width_percent = props.width._percent
        elseif type(props.width) == "number" then
            cfg.width_fixed = props.width
        end
    end
    if props.height ~= nil then
        if is_percent(props.height) then
            cfg.height_percent = props.height._percent
        elseif type(props.height) == "number" then
            cfg.height_fixed = props.height
        end
    end

    if props.padding ~= nil then
        local p = props.padding
        if type(p) == "number" then
            cfg.padding = { p, p, p, p }
        elseif type(p) == "table" then
            if #p == 2 then
                cfg.padding = { p[1], p[2], p[1], p[2] }
            else
                cfg.padding = p
            end
        end
    end

    if props.align then
        cfg.align_x = props.align.x
        cfg.align_y = props.align.y
    end

    return cfg
end

---------------------------------------------------------------------------
-- Internal: walk the tree and emit engine calls.
---------------------------------------------------------------------------

-- Add Clay floating-element fields to a config when the parent is a
-- stack. Children of a stack attach to the stack's rect as floating
-- elements; without explicit sizing they fill the parent (overlap
-- mode, what `clay.max` wants), with explicit `{x, y, width, height}`
-- they sit at absolute parent-relative coords (what `wibox.layout.
-- manual` wants).
local function attach_to_stack(cfg, props)
    cfg.attach_to_parent = true
    if props then
        if props.x then cfg.x_offset = props.x end
        if props.y then cfg.y_offset = props.y end
    end
    -- Default to fill-parent when no explicit sizing was set. Floating
    -- elements with neither percent nor fixed sizing don't pick up the
    -- attached parent's dimensions on their own; setting 100% does.
    -- (The C side divides by 100, so 100 here means 100% of parent.)
    if not cfg.width_fixed and not cfg.width_percent then
        cfg.width_percent = 100
    end
    if not cfg.height_fixed and not cfg.height_percent then
        cfg.height_percent = 100
    end
end

local function emit(node, parent_is_stack)
    local t = node._type
    local cfg = make_config(node.props or {})
    if parent_is_stack then
        attach_to_stack(cfg, node.props)
    end

    if t == "container" then
        clay_c.open_container(cfg)
        local is_stack = node.props and node.props._stack == true
        for _, child in ipairs(node.children) do
            emit(child, is_stack)
        end
        clay_c.close_container()
    elseif t == "widget" then
        clay_c.widget_element(node.widget, cfg)
    elseif t == "client" then
        clay_c.client_element(node.client, cfg)
    elseif t == "drawin" then
        clay_c.drawin_element(node.drawin, cfg)
    elseif t == "workarea" then
        clay_c.workarea_element(cfg)
    else
        error("somewm.layout: unknown node type '" .. tostring(t) .. "'")
    end
end

---------------------------------------------------------------------------
-- Public: layout descriptor (pure data)
---------------------------------------------------------------------------

--- Wrap a layout spec into a descriptor table.
--
-- A descriptor is the static, surface-agnostic description of a layout.
-- It carries no behavior of its own; surface adapters (tag arrange,
-- wibox :layout, decoration apply, layer-shell apply) consume descriptors
-- by calling `layout.solve(descriptor, context)` or its equivalent.
--
-- The descriptor holds a `body` function or a static `tree`. Bindings
-- (`layout.props.X`) and slot specs (`children = layout.first_n(...)`)
-- live inside the tree and are resolved by `subtree` against the
-- supplied context.
--
-- @tparam table spec
-- @tparam string spec.name Human-readable identifier (e.g., "clay.tile").
-- @tparam[opt] function spec.body Tree-builder. Called from `subtree` with
--   the runtime context when `body_signature == "context"`. Surface
--   adapters that still drive their builders with a legacy multi-arg
--   call shape skip `subtree` and call `body` themselves.
-- @tparam[opt] string spec.body_signature `"context"` to opt into the
--   `subtree`-driven pipeline (binding + slot resolution). When unset,
--   the surface adapter is responsible for invoking `body` directly.
-- @tparam[opt] table spec.tree Static container tree (used when `body` is
--   nil and the structure does not depend on runtime context).
-- @tparam[opt] function|boolean spec.skip_gap Per-layout policy hook.
-- @tparam[opt=false] boolean spec.no_gap When true, the layout disowns the
--   tag's `useless_gap` (e.g., a fullscreen layout).
-- @treturn table A descriptor table tagged with `_type = "layout_descriptor"`.
function layout.descriptor(spec)
    return {
        _type          = "layout_descriptor",
        name           = spec.name,
        body           = spec.body,
        body_signature = spec.body_signature,
        tree           = spec.tree or spec[1],
        skip_gap       = spec.skip_gap,
        no_gap         = spec.no_gap,
        bounds_source  = spec.bounds_source,
    }
end

---------------------------------------------------------------------------
-- Public: descriptor-to-tree resolver
---------------------------------------------------------------------------

--- Resolve a layout descriptor against a runtime context, returning a
-- Clay-ready container tree.
--
-- The descriptor is the static description of a layout (the structure of
-- containers, slots, and bindings). The context is the runtime bag the
-- surface provides for this solve (props for bindings, children for slot
-- expansion). The resolver bridges the two: descriptor + context -> tree.
--
-- The pipeline:
--   1. If descriptor.body is a function, call it with context to get a
--      tree. Otherwise the tree is the descriptor's positional `[1]` or
--      `tree` field, or the descriptor itself if it's a container.
--   2. Walk the tree resolving `layout.props.X` bindings against
--      context.props (mutates in place).
--   3. Walk the tree expanding `children = layout.first_n(...)` and
--      similar slot specs against context.children. New leaves are
--      built via `leaf_for(item, context.leaf_kind)`.
--   4. Drop containers whose children all collapsed to nothing (root
--      is preserved even if empty).
--
-- @tparam table descriptor Container node, or a table with `body` (function)
--   or `[1]` (container) describing the tree.
-- @tparam[opt] table context Runtime bag with `bounds`, `props`, `children`,
--   `leaf_kind`, `screen`. When omitted the function is a pure validator
--   pass-through.
-- @treturn table A Clay-ready container node.
function layout.subtree(descriptor, context)
    local tree = descriptor
    if type(descriptor) == "table" and descriptor._type ~= "container" then
        if type(descriptor.body) == "function" then
            tree = descriptor.body(context)
        elseif type(descriptor[1]) == "table" and descriptor[1]._type == "container" then
            tree = descriptor[1]
        elseif type(descriptor.tree) == "table" then
            tree = descriptor.tree
        end
    end

    if not tree or type(tree) ~= "table" or tree._type ~= "container" then
        error("somewm.layout.subtree: descriptor must be a container "
              .. "(use layout.row or layout.column)")
    end

    -- Resolve bindings, expand slots, and drop containers that collapsed
    -- to nothing. Order matters only insofar as slot args (which may be
    -- bindings) are resolved by `expand_slots` itself, so the bindings
    -- pass and the slot pass are independent.
    if context then
        resolve_bindings(tree, context)
        expand_slots(tree, context)
        drop_empty_containers(tree, true)
    end

    return tree
end

---------------------------------------------------------------------------
-- Pure-Lua reference solver. Used when the C engine is not loaded (busted
-- unit-test environment). Implements the same contract as the C engine
-- for the cases wibox layouts and tag presets actually produce: row/column
-- flow with grow/fixed/percent sizing, gap, padding, and stack containers
-- with absolute-positioned children. Cross-axis defaults to filling the
-- container. Output coordinates are floored to match the C engine.
---------------------------------------------------------------------------

local function resolve_size_value(value, parent_size)
    if type(value) == "number" then return value end
    if is_percent(value) then return value._percent * parent_size / 100 end
    return nil
end

-- Clamp absolute-positioned children of a top-level stack root to fit
-- inside the spec bounds. Mutates child props in place so both the C
-- engine and the reference solver see pre-clamped (x, y). Only applies
-- when the spec root is itself a stack: nested stacks would need their
-- bounds resolved first, which we haven't done at this point.
local function apply_top_level_clamp(root, parent_w, parent_h)
    if not root or root._type ~= "container" then return end
    if not (root.props and root.props._stack) then return end
    parent_w = parent_w or 0
    parent_h = parent_h or 0
    for _, child in ipairs(root.children) do
        local cp = child.props
        if cp and cp.clamp then
            local cw = resolve_size_value(cp.width,  parent_w) or parent_w
            local ch = resolve_size_value(cp.height, parent_h) or parent_h
            local cx = cp.x or 0
            local cy = cp.y or 0
            if cx + cw > parent_w then cx = parent_w - cw end
            if cx < 0 then cx = 0 end
            if cy + ch > parent_h then cy = parent_h - ch end
            if cy < 0 then cy = 0 end
            cp.x = cx
            cp.y = cy
        end
    end
end

-- Search for a non-overlapping position for absolute-positioned children
-- of a top-level stack root that carry an `avoid = { rect, ... }` list.
-- The substrate subtracts each obstacle from the parent rect to derive
-- free regions, then picks the largest free region that fits the
-- target. If the requested (x, y) already lands inside a fitting free
-- region, it stays; otherwise the target snaps to the chosen region's
-- top-left. Mutates child props in place.
local function apply_top_level_avoid(root, parent_w, parent_h)
    if not root or root._type ~= "container" then return end
    if not (root.props and root.props._stack) then return end
    parent_w = parent_w or 0
    parent_h = parent_h or 0
    local rect = require("gears.geometry").rectangle
    for _, child in ipairs(root.children) do
        local cp = child.props
        if cp and cp.avoid and #cp.avoid > 0 then
            local cw = resolve_size_value(cp.width,  parent_w) or parent_w
            local ch = resolve_size_value(cp.height, parent_h) or parent_h
            local areas = { { x = 0, y = 0, width = parent_w, height = parent_h } }
            for _, obstacle in ipairs(cp.avoid) do
                areas = rect.area_remove(areas, obstacle)
            end
            local px = cp.x or 0
            local py = cp.y or 0
            local best, best_size = nil, 0
            local fallback, fallback_size = nil, 0
            for _, r in ipairs(areas) do
                local size = r.width * r.height
                if size > fallback_size then
                    fallback, fallback_size = r, size
                end
                if r.width >= cw and r.height >= ch then
                    if size > best_size then
                        best, best_size = r, size
                    end
                    -- Prefer the requested position if it fits inside
                    -- this free region.
                    if px >= r.x and py >= r.y
                        and px + cw <= r.x + r.width
                        and py + ch <= r.y + r.height then
                        best = r
                        best_size = size
                        break
                    end
                end
            end
            if best then
                if px >= best.x and py >= best.y
                    and px + cw <= best.x + best.width
                    and py + ch <= best.y + best.height then
                    -- requested position already fits; keep it
                else
                    cp.x = best.x
                    cp.y = best.y
                end
            elseif fallback then
                -- No fitting region; snap to the biggest free area's
                -- top-left so the client overlaps as little as possible.
                cp.x = fallback.x
                cp.y = fallback.y
            end
        end
    end
end

local function solve_via_reference(spec, root)
    local placements = {}
    local workarea = nil

    local function commit_leaf(node, x, y, w, h)
        if node._type == "workarea" then
            workarea = {
                x      = math.floor(x),
                y      = math.floor(y),
                width  = math.floor(w),
                height = math.floor(h),
            }
            return
        end
        local target = node.widget or node.client or node.drawin
        if not target then return end
        placements[#placements + 1] = {
            widget = target,
            x      = math.floor(x),
            y      = math.floor(y),
            width  = math.floor(w),
            height = math.floor(h),
        }
    end

    local function solve_node(node, bx, by, bw, bh)
        local props = node.props or {}

        if node._type ~= "container" then
            commit_leaf(node, bx, by, bw, bh)
            return
        end

        -- Padding (CSS order: top, right, bottom, left)
        local pad_t, pad_r, pad_b, pad_l = 0, 0, 0, 0
        local p = props.padding
        if type(p) == "number" then
            pad_t, pad_r, pad_b, pad_l = p, p, p, p
        elseif type(p) == "table" then
            if #p == 2 then
                pad_t, pad_r, pad_b, pad_l = p[1], p[2], p[1], p[2]
            elseif #p >= 4 then
                pad_t, pad_r, pad_b, pad_l = p[1], p[2], p[3], p[4]
            end
        end
        local ix = bx + pad_l
        local iy = by + pad_t
        local iw = bw - pad_l - pad_r
        local ih = bh - pad_t - pad_b

        if props._stack then
            for _, child in ipairs(node.children) do
                local cp = child.props or {}
                local cx = ix + (cp.x or 0)
                local cy = iy + (cp.y or 0)
                local cw = resolve_size_value(cp.width,  iw) or iw
                local ch = resolve_size_value(cp.height, ih) or ih
                solve_node(child, cx, cy, cw, ch)
            end
            return
        end

        local is_row     = (props.direction or "row") == "row"
        local main_size  = is_row and iw or ih
        local cross_size = is_row and ih or iw
        local main_key   = is_row and "width"  or "height"
        local cross_key  = is_row and "height" or "width"

        local gap = props.gap or 0
        local n   = #node.children
        local total_gap = math.max(0, n - 1) * gap

        -- Pass 1: base size for each child along main axis.
        local base = {}
        local grow_mask = {}
        local grow_count = 0
        local total_base = 0
        for i, child in ipairs(node.children) do
            local cp = child.props or {}
            local size = resolve_size_value(cp[main_key], main_size)
            if size == nil then
                size = 0
                if cp.grow then
                    grow_mask[i] = true
                    grow_count = grow_count + 1
                end
            end
            base[i] = size
            total_base = total_base + size
        end

        -- Pass 2: distribute leftover space among grow children, capped
        -- by per-child grow_max when set.
        if grow_count > 0 then
            local remaining = main_size - total_base - total_gap
            if remaining > 0 then
                local share = remaining / grow_count
                for i, child in ipairs(node.children) do
                    if grow_mask[i] then
                        local cp = child.props or {}
                        local s = share
                        if cp.grow_max and s > cp.grow_max then
                            s = cp.grow_max
                        end
                        base[i] = base[i] + s
                    end
                end
            end
        end

        -- Pass 3: place each child at cumulative rounded position. Float
        -- accumulator + rounded mirror so total lines up on integer
        -- boundaries (matches flex's expected layout for non-divisible
        -- sizes).
        local pos, pos_rounded = 0, 0
        for i, child in ipairs(node.children) do
            local cp = child.props or {}
            local s = base[i]
            local next_pos = pos + s
            local next_pos_rounded = math.floor(next_pos + 0.5)
            local main_extent = next_pos_rounded - pos_rounded

            local c = resolve_size_value(cp[cross_key], cross_size) or cross_size

            if is_row then
                solve_node(child, ix + pos_rounded, iy, main_extent, c)
            else
                solve_node(child, ix, iy + pos_rounded, c, main_extent)
            end

            pos = next_pos + gap
            pos_rounded = next_pos_rounded + gap
        end
    end

    solve_node(root,
        spec.offset_x or 0, spec.offset_y or 0,
        spec.width or 0, spec.height or 0)

    return { placements = placements, workarea = workarea }
end

---------------------------------------------------------------------------
-- Public: solver
---------------------------------------------------------------------------

--- Solve a layout tree.
--
-- @tparam table spec
-- @tparam number spec.width Available width.
-- @tparam number spec.height Available height.
-- @tparam table spec.root A container node (from `layout.row` / `layout.column`).
-- @tparam[opt] screen spec.screen When set, runs in screen mode: client/
--   drawin geometries are auto-applied unless `no_apply` is set.
-- @tparam[opt=0] number spec.offset_x Screen-mode offset (workarea origin x).
-- @tparam[opt=0] number spec.offset_y Screen-mode offset (workarea origin y).
-- @tparam[opt=false] boolean spec.no_apply Skip auto-apply of client/drawin
--   geometries (compose_screen reads workarea only).
-- @treturn table `{ placements = {...}, workarea = {x,y,w,h}|nil }`. In
--   widget mode `placements` is an array of raw rect tables
--   `{widget, x, y, width, height}`; wibox callers feed these to
--   `wibox.widget.base.place_rects`. In screen mode `placements` is
--   empty (geometries are applied via the engine, not returned to Lua)
--   and `workarea` carries the bounds of the `layout.measure` leaf.
function layout.solve(spec)
    local root = layout.subtree(spec.root, {
        bounds = {
            x      = spec.offset_x or 0,
            y      = spec.offset_y or 0,
            width  = spec.width,
            height = spec.height,
        },
        screen = spec.screen,
    })

    apply_top_level_avoid(root, spec.width, spec.height)
    apply_top_level_clamp(root, spec.width, spec.height)

    -- Busted fallback: pure-Lua reference solver. Implements the same
    -- contract as the C engine for the cases wibox layouts and tag
    -- presets produce. Production always has clay_c; this path runs
    -- only in unit-test environments.
    if not clay_c then
        return solve_via_reference(spec, root)
    end

    local screen = spec.screen
    local opts = nil
    if spec.offset_x or spec.offset_y or spec.source then
        opts = {
            offset_x = spec.offset_x or 0,
            offset_y = spec.offset_y or 0,
            source   = spec.source,
        }
    end

    clay_c.begin_layout(screen, spec.width, spec.height, opts)

    clay_c.open_container(make_config(root.props))
    local root_is_stack = root.props and root.props._stack == true
    for _, child in ipairs(root.children) do
        emit(child, root_is_stack)
    end
    clay_c.close_container()

    local result = { placements = {}, workarea = nil }

    if screen then
        result.workarea = clay_c.end_layout()
        if not spec.no_apply then
            clay_c.apply_all()
        end
    else
        local raw = clay_c.end_layout_to_lua()
        for _, r in ipairs(raw) do
            result.placements[#result.placements + 1] = {
                widget = r.widget,
                x      = math.floor(r.x),
                y      = math.floor(r.y),
                width  = math.floor(r.width),
                height = math.floor(r.height),
            }
        end
        result.workarea = raw.workarea
    end

    return result
end

return layout

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
