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
local beautiful = require("beautiful")
local clay_c = _somewm_clay

local clay = {}

---------------------------------------------------------------------------
-- Screen composition
---------------------------------------------------------------------------

-- Build a somewm.layout subtree for a wibar's widgets so they become real
-- nodes in the merged screen solve. Reuses the wibar drawable's stable context
-- (so fit lookups share its cache) and current geometry as the fit bounds. The
-- subtree fills the drawin's content box; supported containers (align, fixed,
-- margin, background) expand, everything else degrades to a single leaf.
-- Returns nil before the wibar's first draw (no context yet); the wibar then
-- stays a plain drawin leaf that cycle.
local wbase
local function wibar_widget_subtree(wb)
    wbase = wbase or require("wibox.widget.base")
    local top = wb.widget
    local d = wb._drawable
    if not top or not d then return nil end
    local ctx = d:get_widget_context()
    local geo = wb:geometry()
    if not ctx or not geo or geo.width <= 0 or geo.height <= 0 then return nil end
    return wbase.widget_to_node(wbase.no_parent_I_know_what_I_am_doing,
        ctx, top, geo.width, geo.height, { grow = true })
end

-- Provider: one entry per registered wibar, slotted by its screen edge. The
-- consumer batches each edge through layout.drawins. Returns an empty list when
-- the screen has no wibars. (ctx is unused: a wibar needs only the screen.)
local function provider_wibars(s)
    local drawins = s._clay_drawins
    if not drawins then return {} end

    local entries = {}
    for wb, info in pairs(drawins) do
        local entry = { slot = info.position,
            wb = wb, size = info.size, length = info.length,
            stretch = info.stretch, align = info.align,
            clay_gaps = info.clay_gaps, id = "wibar." .. info.position }
        local sub = wibar_widget_subtree(wb)
        if sub then entry.children = { sub } end
        entries[#entries + 1] = entry
    end
    return entries
end

-- Lazy handle to awful.layout (the parent module). compose_screen reuses its
-- parameters()/get() so the merged path agrees with the standalone arrange on
-- the tiled-client set, the gap, and the skip-gap policy. Required lazily
-- because awful.layout pulls in this module.
local _awful_layout
local function awful_layout()
    _awful_layout = _awful_layout or require("awful.layout")
    return _awful_layout
end

-- Lazy handle to awful.client (compose_screen reflects non-tiled clients).
local _aclient
local function aclient()
    _aclient = _aclient or require("awful.client")
    return _aclient
end

-- Lazy handle to awful.titlebar (client_body_subtree folds existing titlebars'
-- widget content into the merged solve). Required lazily to avoid a load cycle.
local _atitlebar
local function atitlebar()
    _atitlebar = _atitlebar or require("awful.titlebar")
    return _atitlebar
end

-- Gather the screen's visible non-tiled clients (floating / fullscreen /
-- maximized = the inverse of client.tiled) as floating-to-root reflection
-- nodes. Each carries the client's CURRENT geometry (+2*border_width per the
-- client-leaf contract) at screen-solve coords, so the merged solve's apply
-- pass round-trips it as a no-op resize (client_resize short-circuits on an
-- equal area): the tree represents these clients without repositioning them.
-- A fullscreen client's geometry is already screen.geometry (set by C), so the
-- same reflection covers the whole screen incl. wibar regions. z rises with
-- stacking height (descriptive only; the single-buffer apply ignores it).
-- Returns nil when there are none. `geo` is the screen geometry (solve origin).
local function collect_floating(s, geo)
    local ac = aclient()
    local stacked = ac.visible(s, true) -- top to bottom
    local out = {}
    local z = 0
    for i = #stacked, 1, -1 do          -- bottom to top: topmost gets highest z
        local c = stacked[i]
        if c.valid and (ac.object.get_floating(c)
            or c.fullscreen or c.maximized
            or c.maximized_vertical or c.maximized_horizontal) then
            local g = c:geometry()
            local bw2 = (c.border_width or 0) * 2
            z = z + 1
            out[#out + 1] = layout.floating_client(c, {
                x      = g.x - geo.x,
                y      = g.y - geo.y,
                width  = g.width  + bw2,
                height = g.height + bw2,
                z      = z,
            })
        end
    end
    if #out == 0 then return nil end
    return out
end

-- Reflect a descriptor-less layout's arrange output as root-attached leaves so
-- the one merged solve positions its clients through the single C apply path.
-- p.geometries holds the OUTER box per client (the same convention the legacy
-- apply loop consumed); this emits the leaf box that, after C subtracts
-- 2*border, lands the exact surface the old loop produced:
--   leaf = (g.x - origin + gap, g.y - origin + gap, g.w - 2*gap, g.h - 2*gap).
-- Read from p.geometries, never c:geometry(): the arrange output is the intent,
-- whereas live geometry is stale until C applies from the tree. This is the
-- sibling of collect_floating (which reflects NON-tiled clients at their LIVE
-- geometry for the descriptor path); here we reflect the arrange OUTPUT for
-- every client the descriptor-less layout positioned. Returns nil when empty.
local function reflect_geometries(p, geo, gap)
    local out, z = {}, 0
    for c, g in pairs(p.geometries) do
        -- Skip clients with no on-screen intersection. Clay culls a fully
        -- off-screen element (it emits no render command), leaving a zeroed
        -- result that clay_apply_all would then apply as a 1x1 box at the screen
        -- origin, clobbering the geometry the layout already applied (e.g.
        -- carousel's scrolled-out columns). Such clients stay applied by the
        -- layout itself, off-tree (the descriptor-less allow-list tolerates the
        -- missing node).
        if c.valid
            and g.x + g.width > geo.x and g.x < geo.x + geo.width
            and g.y + g.height > geo.y and g.y < geo.y + geo.height then
            z = z + 1
            out[#out + 1] = layout.floating_client(c, {
                x      = g.x - geo.x + gap,
                y      = g.y - geo.y + gap,
                width  = g.width  - 2 * gap,
                height = g.height - 2 * gap,
                z      = z,
            })
        end
    end
    if #out == 0 then return nil end
    return out
end

-- Walk a tree, setting `gap` on every container that doesn't already have one
-- set. Mirrors the legacy walk_with_gap semantic so nested containers
-- (tile/fair/spiral) inherit the tag's useless_gap as childGap.
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

-- Resolve a layout descriptor into the root container `layout.solve` expects:
-- run the body, expand its bindings/slots against the tiled clients, force
-- grow, and propagate the gap. Returns the root and the bounds it resolved
-- against (p.workarea or p.geometry), or nil when there are no clients to
-- place. Shared by the standalone arrange (suit.arrange) and the merged
-- compose_screen path so both produce the identical client tree.
local function descriptor_to_root(descriptor, p)
    local wa = (descriptor.bounds_source == "geometry")
        and p.geometry or p.workarea
    local gap = descriptor.no_gap and 0 or p.useless_gap
    local s = capi.screen[p.screen]
    local t = p.tag or s.selected_tag
    if #p.clients == 0 then return nil end

    local tree
    if descriptor.body_signature == "context" then
        tree = layout.subtree(descriptor, {
            bounds    = wa,
            props     = t,
            children  = p.clients,
            leaf_kind = "client",
            screen    = s,
            params    = p,
        })
    elseif type(descriptor.body) == "function" then
        tree = descriptor.body(p.clients, wa, t, p)
    elseif descriptor.tree then
        tree = descriptor.tree
    end
    if not tree then return nil end

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
    -- Name the client container after the layout for the debug inspector.
    if not root.props.id then
        root.props.id = descriptor.name or "layout"
    end
    return root, wa
end

-- The widget a node maps to, or nil for a purely structural node (e.g. align's
-- flex filler row). Container widgets carry their widget at props.widget (set by
-- the container's :layout_node); widget leaves carry it at .widget.
local function node_widget(node)
    if node._type == "widget" then return node.widget end
    if node._type == "container" then return node.props and node.props.widget end
    return nil
end

-- Walk a wibar's widget node tree and, for every widget-tagged container, record
-- the placement list its `:layout` would have produced -- but read straight from
-- the merged solve's boxes instead of re-solving. Keyed by the container widget;
-- consumed by wibox/hierarchy.lua. Children with no widget (structural fillers)
-- are skipped, matching what `:layout` places. Recurses so nested containers are
-- covered; a child that degraded to a leaf (its own subtree not in the merged
-- tree) gets no entry and falls back to its `:layout` solve.
local function collect_placements(node, boxmap, out)
    if not node or node._type ~= "container" then return end
    local w = node.props and node.props.widget
    if not w then
        for _, child in ipairs(node.children) do
            collect_placements(child, boxmap, out)
        end
        return
    end
    wbase = wbase or require("wibox.widget.base")
    local mybox = boxmap[w]
    local pls, complete = {}, mybox ~= nil
    for _, child in ipairs(node.children) do
        local cw = node_widget(child)
        if cw then
            local cbox = mybox and boxmap[cw]
            if cbox then
                pls[#pls + 1] = wbase.place_widget_at(cw,
                    cbox.x - mybox.x, cbox.y - mybox.y, cbox.width, cbox.height)
            else
                complete = false
            end
        end
        -- Always recurse: a missing box only disqualifies THIS container, not
        -- its descendants, which may be fully covered on their own.
        collect_placements(child, boxmap, out)
    end
    -- Only claim this container when every child resolved; otherwise it falls
    -- back to its :layout solve (a partial list would drop real children).
    if complete then out[w] = pls end
end

-- Walk a framed client subtree and, for every titlebar node, collect its widget
-- root's placements (via collect_placements) into the shared placement map. The
-- titlebar's widget root box == the titlebar box, so collect_placements re-bases
-- the content to titlebar-local coords -- exactly what the titlebar drawable's
-- client-relative paint expects.
local function collect_titlebar_placements(node, boxmap, out)
    if type(node) ~= "table" then return end
    if node._type == "titlebar" then
        if node.children and node.children[1] then
            collect_placements(node.children[1], boxmap, out)
        end
    elseif node.children then
        for _, child in ipairs(node.children) do
            collect_titlebar_placements(child, boxmap, out)
        end
    end
end

-- Build a titlebar node that folds its widget content into the merged solve, or
-- nil to fall back to a box-only frame_box. Returns nil when the titlebar has no
-- size, no existing drawable (never call the lazy-creating getters during a
-- solve), no root widget, or no usable geometry yet (mirrors the wibar's
-- first-draw guard). The sizing table is byte-identical to the box-only frame_box
-- it replaces, so the titlebar's outer box -- and thus the surface box -- never
-- moves when titlebar content reflows. As a side effect it points the drawable at
-- the client's screen and hooks its widget relayout to a screen arrange, so the
-- content re-solves through this merged tree (mirrors the wibar wiring).
local function titlebar_node(c, position, role, size, sizing)
    if size <= 0 then return nil end
    local d = atitlebar().get_existing(c, position)
    if not d then return nil end
    local top = d:get_widget()
    if not top then return nil end

    -- Point the drawable at the client's screen: a titlebar's drawin geometry is
    -- client-relative, not absolute screen space, so do_redraw can't resolve the
    -- screen by coordinate -- it must use _forced_screen to pick the right dpi and
    -- this screen's merged placements. Keep it synced via property::screen so it
    -- follows the client across outputs; otherwise a stale _forced_screen left on a
    -- removed (invalid) screen would make do_redraw bail forever (blank titlebar).
    d._forced_screen = c.screen
    if not d._clay_arrange_hooked then
        d._clay_arrange_hooked = true
        c:connect_signal("property::screen", function()
            d._forced_screen = c.screen
        end)
        -- Re-solve the screen tree when the titlebar's widgets change size, so its
        -- content reflows through the screen solve under any layout. This (titlebar
        -- widget relayout) and the wibar's layout_changed hook in awful.wibar are
        -- the complete set of widget -> arrange edges: a widget that only repaints
        -- never reaches here.
        d:connect_signal("layout_changed", function()
            local sc = c.screen
            if not (sc and sc.valid) then return end
            awful_layout().arrange(sc)
        end)
    end

    wbase = wbase or require("wibox.widget.base")
    local ctx = d:get_widget_context()
    local geo = d.drawable and d.drawable:geometry()
    if not ctx or not geo or geo.width <= 0 or geo.height <= 0 then return nil end
    local wnode = wbase.widget_to_node(wbase.no_parent_I_know_what_I_am_doing,
        ctx, top, geo.width, geo.height, { grow = true })
    if not wnode then return nil end
    return layout.titlebar(role, sizing, wnode)
end

-- Build a framed client's body subtree: a body column (titlebars + surface)
-- carrying the client border as a Clay `.border` config plus `.padding = bw`,
-- which insets the titlebars and surface by the border width (replacing the
-- four border frame_box leaves that used to reserve that ring). The border is
-- drawn onto the four border scene rects by arithmetic (frame_apply_boxes), not
-- solved as layout boxes; the `.border` config is the declared value shown in
-- `clay tree` and the Clay debug inspector. Each titlebar folds its widget
-- content into the merged solve when its drawable exists, else it is a box-only
-- frame_box; the titlebar / surface boxes route into the client's merged_frame,
-- and the surface grows to fill the body minus the titlebars. Sizes come from a
-- side-effect-free C read (no titlebar drawable creation).
local function client_body_subtree(c)
    local FRAME = clay_c.frame
    local bw, tt, tr, tb, tl = clay_c.client_frame_sizes(c)
    -- Each titlebar folds its widget content into the merged solve when its
    -- drawable already exists; otherwise it stays a box-only frame_box.
    local function tbar(position, role, size, sizing)
        return titlebar_node(c, position, role, size, sizing)
            or layout.frame_box(role, sizing)
    end
    return layout.column { -- client body: border ring + titlebars + surface
        grow    = true,
        border  = bw > 0
            and { width = bw, color = c.border_color or beautiful.border_color_normal }
            or nil,
        padding = bw,
        tbar("top", FRAME.titlebar_top, tt, { height = tt, grow = true }),
        layout.row {
            grow = true,
            tbar("left", FRAME.titlebar_left, tl, { width = tl, grow = true }),
            layout.frame_box(FRAME.surface,   { grow = true }),
            tbar("right", FRAME.titlebar_right, tr, { width = tr, grow = true }),
        },
        tbar("bottom", FRAME.titlebar_bottom, tb, { height = tb, grow = true }),
    }
end

-- Attach the border/body subtree to every client leaf in a resolved tiled
-- subtree, so emit routes each client through client_open/close and the merged
-- solve computes its border/titlebar/surface boxes. Floating / magnifier /
-- non-merged clients are not framed; they keep the per-client frame solve
-- (apply_geometry_to_wlroots falls back when merged_frame is absent).
local function frame_clients(node)
    if type(node) ~= "table" then return end
    if node._type == "client" then
        node.children = { client_body_subtree(node.client) }
    elseif node.children then
        for _, child in ipairs(node.children) do
            frame_clients(child)
        end
    end
end

---------------------------------------------------------------------------
-- Provider model
--
-- compose_screen builds one per-solve `ctx`, then drains an ordered list of
-- providers into slot buckets and assembles the screen tree from them. A
-- provider is `provider(s, ctx) -> entries`; every entry declares a `slot`:
--   * edge slots "top" / "bottom" / "left" / "right" -- wibar entries, batched
--     per edge through `layout.drawins(side, axis, ctx.gap)`;
--   * "workarea" -- the 0..1 client subtree parented under the measure node;
--   * "root" -- z-ordered root-attached subtrees (fullscreen graft / floats /
--     reflected).
-- A provider may also set the provider-written ctx fields (framed_root, merged,
-- laid) as a side effect; the solve/placement tail reads them.
---------------------------------------------------------------------------

-- Build the per-solve ctx: the read-only screen/layout values every provider
-- and the assembly share, plus the provider-written fields they fill in. The
-- single source for a value read once per solve (the resolved suit, the layer
-- zones, the tag gap), so a provider and the assembly never recompute or
-- disagree. Note `gap` (the tag gap, used for the measure padding and the wibar
-- drawins) is NOT `p.useless_gap` (the per-client inset); they are distinct.
local function build_ctx(s, p)
    local t = s.selected_tag
    local lz_top, lz_right, lz_bottom, lz_left = clay_c.layer_exclusive(s)
    local suit = awful_layout().get(s)
    return {
        s             = s,
        p             = p,
        geo           = s.geometry,
        gap           = (t and t.gap) or 0,
        suit          = suit,
        merge_capable = (suit and suit.descriptor) and true or false,
        debug_resolve = s._clay_debug_resolve,
        lz_top        = lz_top,    lz_right = lz_right,
        lz_bottom     = lz_bottom, lz_left  = lz_left,
        -- provider-written:
        framed_root   = nil,
        merged        = false,
        laid          = false,
    }
end

-- Provider: the tiled clients. A merge-capable layout owns the whole screen solve
-- (wibars + workarea + clients): it resolves its client subtree, frames it, and
-- emits it as the workarea child -- or, for a fullscreen `bounds_source ==
-- "geometry"` layout (clay.max.fullscreen), as a root graft spanning the whole
-- screen (covering the wibar regions, not the wibar-inset workarea) so the same
-- subtree the standalone preset solved against p.geometry solves here against the
-- same box. A descriptor-less layout (magnifier / carousel / a user's arrange) ran
-- its arrange before this call and filled p.geometries; its boxes are reflected as
-- root leaves so the one solve owns its clients too (debug_resolve carries no fresh
-- p.geometries, so it is skipped: the overlay repaints from the last real arrange).
-- Every descriptor lays its clients in this one solve: having a descriptor IS being
-- merge-capable; merge_capable stays a public descriptor field but no longer gates.
-- Sets ctx.framed_root (for the titlebar placement pass), ctx.merged (the
-- float gate), and ctx.laid (this solve placed the clients) for the solve +
-- placement tail. Emits at most one entry, none when no clients were placed.
local function provider_clients(s, ctx)
    local p = ctx.p
    if ctx.merge_capable then
        local root = descriptor_to_root(ctx.suit.descriptor, p)
        if not root then return {} end
        frame_clients(root)
        ctx.framed_root = root
        ctx.merged = true
        ctx.laid = true
        if ctx.suit.descriptor.bounds_source == "geometry" then
            return { { slot = "root", node = layout.attach_to_root(root, {
                x = 0, y = 0,
                width = ctx.geo.width, height = ctx.geo.height,
            }) } }
        end
        -- Place the clients in the same box the standalone tile solve used: the
        -- workarea node's inner box (screen.workarea, after the gap padding) minus
        -- screen.padding and useless_gap. Mirrors get_bounding_geometry{
        -- honor_padding, margins = gap }.
        local pad = s.padding or {}
        local ug = p.useless_gap or 0
        return { { slot = "workarea", node = layout.row {
            grow    = true,
            padding = {
                (pad.top or 0) + ug, (pad.right or 0) + ug,
                (pad.bottom or 0) + ug, (pad.left or 0) + ug,
            },
            root,
        } } }
    end

    if not ctx.debug_resolve and p.geometries then
        local reflected = reflect_geometries(p, ctx.geo, p.useless_gap or 0)
        if reflected then
            ctx.laid = true
            return { { slot = "root", node = reflected } }
        end
    end
    return {}
end

-- Provider: the screen's floating / fullscreen / maximized clients reflected as
-- root leaves over a MERGED (descriptor) tile, so the one solve represents every
-- client. Gated on ctx.merged, so it must run after provider_clients: a
-- descriptor-less layout already reflected all its clients (running both would
-- double-reflect). These clients are removed from flow, so the wibar / workarea
-- layout is unaffected. Emits one root entry, or none.
local function provider_floats(s, ctx)
    if not ctx.merged then return {} end
    local floats = collect_floating(s, ctx.geo)
    if not floats then return {} end
    return { { slot = "root", node = floats } }
end

-- Ordered list of providers drained by compose_screen. Order is load-bearing:
-- provider_clients before provider_floats (floats reads ctx.merged, which
-- provider_clients sets) and, in the root z-stack, the clients' graft / reflected
-- before the floats.
local node_providers = { provider_wibars, provider_clients, provider_floats }

--- Build the screen-level layout tree, solve it, and write screen.workarea.
-- Called once per layout cycle from `awful.layout._recompute_screen`. Returns
-- true when this solve laid out the clients itself, either a merge-capable
-- descriptor (tile/fair/...) or a descriptor-less layout whose arrange output
-- (p.geometries) is reflected as root-attached leaves; the caller then skips
-- the imperative per-client apply.
-- @tparam[opt] table p The arranged params (carrying p.geometries) from the
--   drain. When omitted (the wibar registration and debug-overlay callers) only
--   the wibars + workarea are solved and clients are left untouched.
function clay.compose_screen(s, p)
    -- The drain passes the arranged params so a descriptor-less layout's
    -- p.geometries can be reflected into this one solve. The wibar / debug
    -- callers pass none and only need the wibar + workarea solve.
    p = p or awful_layout().parameters(nil, s)
    local ctx = build_ctx(s, p)

    -- Drain every provider into slot buckets in one pass: edge wibars
    -- (top/bottom/left/right), the single workarea child, and the z-ordered root
    -- list. Provider order is load-bearing for the root z-stack (the clients'
    -- graft / reflected, then the floats). has_wibar tracks edge slots ONLY, so a
    -- clients- or floats-only solve still nils out `wibars`, preserving the old
    -- "no drawins" short-circuit.
    local wibars = { top = {}, bottom = {}, left = {}, right = {} }
    local has_wibar = false
    local workarea_children, root_nodes = nil, {}
    for _, provider in ipairs(node_providers) do
        for _, entry in ipairs(provider(s, ctx)) do
            local side = wibars[entry.slot]
            if side then
                side[#side + 1] = entry
                has_wibar = true
            elseif entry.slot == "workarea" then
                workarea_children = entry.node
            elseif entry.slot == "root" then
                root_nodes[#root_nodes + 1] = entry.node
            end
        end
    end
    if not has_wibar then wibars = nil end

    local geo = ctx.geo
    local gap = ctx.gap

    -- A debug-overlay re-solve (clay.debug_resolve, driven by pointer motion)
    -- only needs end_layout to redraw the Clay debug view; geometry was already
    -- applied by the last real arrange. Suppress the apply, the workarea write,
    -- and the widget-placement rebuild so this pass never moves clients or
    -- clobbers the real arrange's state.
    local debug_resolve = ctx.debug_resolve

    -- Layer-shell exclusive zones reserve screen edges before any wibar.
    -- arrangelayers() in protocols.c populates these on layer-surface commit.
    local lz_top, lz_right, lz_bottom, lz_left =
        ctx.lz_top, ctx.lz_right, ctx.lz_bottom, ctx.lz_left

    local framed_root = ctx.framed_root
    -- This solve laid out the clients (a merged descriptor or a descriptor-less
    -- reflection, both set by provider_clients via ctx.laid); the caller then
    -- skips the imperative per-client apply.
    local laid = ctx.laid

    -- The workarea node reports screen.workarea (its inner box, after the gap
    -- padding). On the merged tile path it also parents the client subtree; the
    -- fullscreen graft and the floats / reflected attach to the root below.
    local measure = workarea_children
        and layout.measure { padding = gap, grow = true, workarea_children }
        or  layout.measure { padding = gap, grow = true }

    local has_lr = wibars and (#wibars.left > 0 or #wibars.right > 0)
    local middle
    if has_lr then
        middle = layout.row {
            grow = true,
            layout.drawins(wibars.left, "width", gap),
            measure,
            layout.drawins(wibars.right, "width", gap),
        }
    else
        middle = measure
    end

    local col = {
        id = "screen",
        grow = true,
        padding = { lz_top, lz_right, lz_bottom, lz_left },
        layout.drawins(wibars and wibars.top or nil, "height", gap),
        middle,
        layout.drawins(wibars and wibars.bottom or nil, "height", gap),
    }
    -- Root-attached subtrees in provider z-order: the descriptor graft or the
    -- descriptor-less reflection, then the floats over a merged tile.
    for _, node in ipairs(root_nodes) do col[#col + 1] = node end

    local result = layout.solve {
        screen = s,
        source = laid and "merged" or "compose_screen",
        width = geo.width, height = geo.height,
        offset_x = geo.x, offset_y = geo.y,
        no_apply = debug_resolve,
        -- debug_only also tells C to skip has_pending, so the deferred
        -- clay_apply_all does not re-apply this pass's (unchanged) geometry.
        debug_only = debug_resolve,
        root = layout.column(col),
    }

    if debug_resolve then
        return laid
    end

    if result.workarea then
        clay_c.set_screen_workarea(s,
            result.workarea.x, result.workarea.y,
            result.workarea.width, result.workarea.height)
    end

    -- Turn the solved widget boxes into per-container placement lists so each
    -- merged wibar's hierarchy can paint from this one screen solve instead of
    -- re-running the per-container "wibox" forest. wibox/drawable.lua reads
    -- s._clay_widget_placements. Boxes floored to match the forest's integer
    -- placements; the map is weak-keyed so dead widgets don't pin.
    local boxmap = {}
    if result.widgets then
        for _, r in ipairs(result.widgets) do
            boxmap[r.widget] = {
                x      = math.floor(r.x),     y      = math.floor(r.y),
                width  = math.floor(r.width), height = math.floor(r.height),
            }
        end
    end
    local placements = setmetatable({}, { __mode = "k" })
    if wibars then
        for _, side in ipairs({ wibars.top, wibars.bottom, wibars.left, wibars.right }) do
            for _, entry in ipairs(side) do
                if entry.children and entry.children[1] then
                    collect_placements(entry.children[1], boxmap, placements)
                end
            end
        end
    end
    -- Titlebar widget content is folded into the same merged solve as the wibars;
    -- collect each framed client's titlebar placements into the shared map so the
    -- titlebar drawables paint from this solve instead of their wibox forest.
    if framed_root then
        collect_titlebar_placements(framed_root, boxmap, placements)
    end
    s._clay_widget_placements = placements

    return laid
end

---------------------------------------------------------------------------
-- Tiled-client layout factory
---------------------------------------------------------------------------

-- Adapter: wrap a layout descriptor as a tag-suit.
--
-- A descriptor is pure data (`somewm.layout.descriptor`); a tag-suit is
-- the `{name, arrange, skip_gap?}` shape `awful.layout.arrange` expects.
-- The descriptor is exposed at `suit.descriptor` so `compose_screen` can
-- resolve it into the merged screen solve (`descriptor_to_root`).
--
-- A descriptor's clients are laid out by compose_screen (descriptor_to_root),
-- never by this arrange: the per-screen drain runs arrange only for
-- descriptor-less layouts. suit.arrange is kept as a no-op so a descriptor
-- layout still exposes the conventional arrange method.
local function tag_suit_from_descriptor(descriptor)
    local suit = {
        name        = descriptor.name,
        skip_gap    = descriptor.skip_gap,
        descriptor  = descriptor,
    }

    function suit.arrange() end

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
-- Debug view (Clay hierarchy inspector + hover highlight)
---------------------------------------------------------------------------

--- Re-solve one screen purely to repaint the Clay debug overlay (no geometry
-- apply). Driven from C (clay_debug_tick) on pointer motion while debug is on.
-- @tparam screen s
function clay.debug_resolve(s)
    s._clay_debug_resolve = true
    pcall(clay.compose_screen, s)
    s._clay_debug_resolve = nil
end

--- Turn the Clay debug view on or off.
-- Enabling shrinks the desktop by the panel width (like the Clay website) and
-- shows the inspector panel; a normal arrange reflows windows into the freed
-- space and the end_layout pass paints the overlay. Disabling reflows back to
-- full width and hides it.
-- @tparam boolean on
function clay.set_debug(on)
    if not clay_c or not clay_c.set_debug_enabled then return end
    clay_c.set_debug_enabled(on and true or false)
    for s in capi.screen do
        awful_layout().arrange(s)
    end
end

--- Flip the Clay debug view on/off. Bind this to a key in rc.lua.
function clay.toggle_debug()
    if not clay_c or not clay_c.is_debug_enabled then return end
    clay.set_debug(not clay_c.is_debug_enabled())
end

-- Register the C-side resolver once. clay_debug_tick calls it to rebuild +
-- re-solve screens (Clay cannot rebuild its element tree alone). reflow=true
-- does a normal arrange of every screen (after a panel-close self-disable, so
-- windows reflow back to full width); reflow=false repaints the debug overlay.
if clay_c and clay_c.set_debug_resolver then
    clay_c.set_debug_resolver(function(reflow)
        for s in capi.screen do
            if reflow then
                awful_layout().arrange(s)
            else
                clay.debug_resolve(s)
            end
        end
    end)
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
