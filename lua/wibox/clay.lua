---------------------------------------------------------------------------
--- Compile a drawable's widget tree into Clay declarations.
--
-- The declare pass (declare.c) draws a drawin from the tree this module
-- returns: one element per described widget, with image elements referencing
-- their own surfaces. A widget that draws itself or has no describer is
-- refused together with its subtree; the drawable background remains.
--
-- The walk descends the widget tree itself, not a laid-out hierarchy: Clay
-- is the only solver of a converted tree, and the walk computes no box,
-- only the offer each node passes down. A node's sizing is one of the four
-- types clay.h names: `fit` wraps the content, which is Clay's default
-- (CLAY_SIZING_FIT), `grow` fills the parent (CLAY_SIZING_GROW), a number
-- is told (CLAY_SIZING_FIXED), and a table `{ percent = p }` is a share of
-- the parent (CLAY_SIZING_PERCENT, clay.h:66-72, 289-297). A container
-- says which of the first two each child gets, in place of the
-- `:fit` question the layout engine asked; a widget's own preference (a
-- forced size, a place that fills) refines fit and never overrides grow,
-- since fit is the content size and that preference is the content.
--
-- The offer is the box the engine's `:fit` was asked with: the drawin at
-- the root, less each node's padding on the way down. A node may divide
-- the offer among its children along one axis. Clay measures
-- nothing but text (Clay_SetMeasureTextFunction, clay.h:889), and an image
-- element is a bare pointer (Clay_ImageElementConfig, clay.h:414-416), so
-- a node that says `aspect` or `square` is told both sizes from the offer,
-- a forced axis standing. A cap of `"offer"` (`wmax`, `hmax`) is the
-- offer on that axis, for a node whose content it cuts rather than
-- outgrows. A described leaf gives its preferred dimensions directly, using
-- grow on an axis that takes the whole offer.
--
-- @module wibox.clay
---------------------------------------------------------------------------

local gdebug = require("gears.debug")
local beautiful = require("beautiful")
local gcolor = require("gears.color")
local gshape = require("gears.shape")
local gsurface = require("gears.surface")

local cairo = require("lgi").cairo
local clay = {}
local probe = cairo.Context(cairo.ImageSurface(cairo.Format.A8, 1, 1))

--- Record a shape path in logical pixels, offset by dx and dy.
function clay.shape_ops(shape, w, h, dx, dy, ...)
    probe:new_path()
    local ops = {}
    local kinds = { MOVE_TO = 0, LINE_TO = 1, CURVE_TO = 2, CLOSE_PATH = 3 }
    local function append_path()
        for kind, points in probe:copy_path():pairs() do
            ops[#ops + 1] = kinds[kind]
            for _, point in ipairs(points) do
                ops[#ops + 1] = point.x + (dx or 0)
                ops[#ops + 1] = point.y + (dy or 0)
            end
        end
    end
    local recorder = setmetatable({}, { __index = function(_, name)
        if name == "stroke" or name == "fill" then
            return function()
                append_path()
                probe:new_path()
            end
        elseif name == "stroke_preserve" or name == "fill_preserve" then
            return append_path
        end
        return function(_, ...)
            return probe[name](probe, ...)
        end
    end })
    shape(recorder, w, h, ...)
    append_path()
    return ops
end

--- The corner radius a shape stands for, or nil for one Clay cannot name.
-- A shape is an arbitrary painter: the two gears shapes that are rectangles
-- are known by identity, and any other function by the path it draws;
-- `rounded_bar` and the rest keep drawing themselves.

local function same_path(a, b)
    if #a ~= #b then
        return false
    end
    for i, value in ipairs(a) do
        if value ~= b[i] then
            return false
        end
    end
    return true
end

--- The radius a shape function draws when its path is
-- gears.shape.rounded_rect's, which is what a theme's `function(cr, w, h)
-- gears.shape.rounded_rect(cr, w, h, r) end` draws: the same path at two
-- sizes, with the radius read off the path's first point (0, r). Cached
-- per function; false for one that draws anything else.
local shape_radii = setmetatable({}, { __mode = "k" })

local function closure_radius(shape)
    local r = shape_radii[shape]

    if r == nil then
        local w, h = 160, 96
        local path = clay.shape_ops(shape, w, h)

        r = false
        if path[1] == 0 and path[2] == 0 then
            local radius = path[3]

            if same_path(path, clay.shape_ops(gshape.rounded_rect, w, h, 0, 0, radius))
                    and same_path(clay.shape_ops(shape, 2 * w, 2 * h),
                        clay.shape_ops(gshape.rounded_rect, 2 * w, 2 * h, 0, 0, radius)) then
                r = radius
            end
        end
        shape_radii[shape] = r
    end
    return r or nil
end

local function shape_radius(shape, args)
    if shape == nil or shape == gshape.rectangle then
        return 0
    end
    if shape == gshape.rounded_rect then
        local r = args and args[1] or 10

        return (type(r) == "number" and r >= 0) and r or nil
    end
    if type(shape) == "function" then
        return closure_radius(shape)
    end
    return nil
end

clay.shape_radius = shape_radius

--- The straight-alpha components of a solid color pattern, or nil for a
-- gradient, a surface pattern, or no color at all. A solid color carries
-- four components (third_party/clay.h:223-225); the renderer uses straight alpha.
local function solid_rgba(col)
    if not col then
        return nil
    end

    local pattern = gcolor(col)

    if pattern:get_type() ~= "SOLID" then
        return nil
    end

    local status, r, g, b, a = pattern:get_rgba()

    if status ~= "SUCCESS" then
        return nil
    end

    return { r, g, b, a }
end

--- A solid fill or a linear or radial gradient in logical pixels.
function clay.fill(col)
    if not col then return nil end
    local pattern = gcolor(col)
    local kind = pattern:get_type()
    if kind == "SOLID" then return solid_rgba(col) end
    if kind ~= "LINEAR" and kind ~= "RADIAL" then return nil end
    local status, count = pattern:get_color_stop_count()
    if status ~= "SUCCESS" or count > 16 then return nil end
    local points = kind == "LINEAR" and { pattern:get_linear_points() }
        or { pattern:get_radial_circles() }
    if table.remove(points, 1) ~= "SUCCESS" then return nil end
    local fill = { stops = {} }
    fill[kind == "LINEAR" and "linear" or "radial"] = points
    for i = 0, count - 1 do
        local stop = { pattern:get_color_stop_rgba(i) }
        if table.remove(stop, 1) ~= "SUCCESS" then return nil end
        fill.stops[#fill.stops + 1] = stop
    end
    return fill
end

--- The spec for a container's only child: the whole padded box, which is
-- what `margin:layout` and `background:layout` place it at.
local function whole_box(widget)
    return widget and { { widget = widget, w = "grow", h = "grow" } } or {}
end

--- The parent's sizing for a child, over the child's own. Grow stands, and
-- a size the child gave becomes its floor (Clay_SizingMinMax.min): the
-- child fills what it is given, and a parent that wraps its content still
-- counts that size, as the engine's `:fit` counted it through a container
-- that hands its child the whole box. Fit gives way to what the child said.
-- A floor from either side stands, and the larger of two.
local function merge_sizing(node, spec)
    for _, k in ipairs { "w", "h" } do
        if spec[k] == "grow" then
            if type(node[k]) == "number" then
                node[k .. "min"] = node[k]
            end
            node[k] = "grow"
        elseif node[k] == nil then
            node[k] = spec[k]
        end
    end
    for _, k in ipairs { "wmin", "hmin" } do
        if spec[k] and node[k] then
            node[k] = math.max(spec[k], node[k])
        else
            node[k] = spec[k] or node[k]
        end
    end
    -- A cap from either side stands, and the tighter of two.
    for _, k in ipairs { "wmax", "hmax" } do
        if spec[k] and node[k] then
            node[k] = math.min(spec[k], node[k])
        else
            node[k] = spec[k] or node[k]
        end
    end
end

--- awful.widget.systray_icon -> an element centering one image leaf: the
-- item's pixmap, or the icon file its name resolves to, at the slot's
-- square scaled to keep the icon's aspect, as `systray_icon:draw` paints
-- it (third_party/clay.h:414-416). Hover, urgency, overlays and
-- `beautiful.systray_icon_style` are ignored. An icon without a usable
-- pixmap or icon file is refused.
function clay.systray_icon(w)
    local p = w._private
    local item = p.item

    if not item then
        return clay.refuse(w, "icon", "has no pixmap and no icon file to draw")
    end
    if p.is_hovered then
        clay.ignore(w, "is_hovered", "is drawn as the plain icon")
    end
    if item.status == "NeedsAttention" then
        clay.ignore(w, "status", "is drawn as the plain icon")
    end
    if item.overlay_icon then
        clay.ignore(w, "overlay_icon", "is drawn as the plain icon")
    end
    if beautiful.systray_icon_style then
        clay.ignore(w, "systray_icon_style", "is drawn as the plain icon")
    end

    local size = p.forced_size or 24
    local sw, sh = p.forced_width or size, p.forced_height or size
    local surface, iw, ih = item:_icon_surface()

    if not surface then
        -- The icon file, loaded once per path so the surface the leaf
        -- references stays the same object across compiles.
        local path = p.current_icon

        if type(path) ~= "string" then
            return clay.refuse(w, "icon", "has no pixmap and no icon file to draw")
        end
        if not p.clay_icon or p.clay_icon.path ~= path then
            local loaded = gsurface.load_silently(path)

            if not loaded then
                return clay.refuse(w, "icon", "has no pixmap and no icon file to draw")
            end
            p.clay_icon = { path = path, surface = loaded }
        end
        surface = p.clay_icon.surface._native
        iw, ih = p.clay_icon.surface.width, p.clay_icon.surface.height
    end
    if not (iw > 0 and ih > 0) then
        return clay.refuse(w, "icon", "has no pixmap and no icon file to draw")
    end

    local scale = math.min(sw / iw, sh / ih)

    return { w = sw, h = sh, align = { x = "center", y = "center" },
        specs = { { image = surface, class = "image",
            w = math.ceil(iw * scale), h = math.ceil(ih * scale) } } }
end

--- wibox.widget.systray -> the fixed layout it is, with the padding and
-- the background its overrides add (`beautiful.systray_paddings`,
-- `beautiful.bg_systray`) and the least size its `:fit` answers. More than
-- one row is drawn as one; spacing widgets and a non-solid background
-- are ignored. Padding and spacing round to uint16 pixels
-- (third_party/clay.h:330-335, 344).
function clay.systray(w)
    local p = w._private
    local padding = clay.pixels(w, "systray_paddings", beautiful.systray_paddings)
    local rows = math.floor(tonumber(beautiful.systray_max_rows) or 1)
    local spacing = clay.pixels(w, "spacing", p.spacing)
    local size = w.base_size or 24

    if rows > 1 then
        clay.ignore(w, "systray_max_rows", "above 1 is one row")
    end
    if spacing ~= 0 and p.spacing_widget then
        clay.ignore(w, "spacing_widget", "is not drawn")
    end

    local along, across = "w", "h"

    if p.dir == "y" then
        along, across = "h", "w"
    end

    local node = { dir = p.dir, gap = spacing, specs = {},
        pad = { padding, padding, padding, padding },
        [along .. "min"] = padding * 2 + size }

    if beautiful.bg_systray then
        node.bg = solid_rgba(beautiful.bg_systray)
        if not node.bg then
            clay.ignore(w, "bg_systray", "is not solid and is transparent")
        end
    end
    for i, child in ipairs(p.widgets) do
        node.specs[i] = { widget = child, [across] = "grow" }
    end
    return node
end

--- Register the describer for one widget.
-- @tparam wibox.widget w The widget.
-- @tparam function describer The describer, as the class table's entries.
-- @tparam string name The widget's class, for the `somewm-client clay
--  tree` dump, where `widget_name` names the class it was built from.
-- @staticfct wibox.clay.describe_widget
function clay.describe_widget(w, describer, name)
    w._clay = { describe = describer, name = name }
end


--- The widget's class, for the `somewm-client clay tree` dump.
--
-- `gears.object.modulename` derives `widget_name` from the source path and
-- only trims it at a `lib/` directory; somewm installs its library under
-- `lua/`, so the name arrives with the path still in front of it.
local function class_name(w)
    local name = w._clay and w._clay.name or w.widget_name

    if not name then
        return nil
    end
    return (name:gsub("^.*%.lua%.", ""):gsub("^[^%a]+", ""))
end

local warned = {}
local warned_props = {}

--- Warn once per class and property that a value Clay cannot hold is
-- left out, and go on without it. `who` is a widget or a name.
function clay.ignore(who, property, what)
    local name = type(who) == "string" and who or class_name(who) or "?"
    local key = name .. " " .. property
    if not warned_props[key] then
        warned_props[key] = true
        gdebug.print_warning("wibox.clay: " .. key .. " " .. what)
    end
end

--- The same warning for a property that keeps the widget out of the
-- tree; a describer returns it.
function clay.refuse(who, property, what)
    clay.ignore(who, property, what .. " and is left out of the tree")
    return nil
end

--- The nearest whole pixel.
function clay.round(v)
    return math.floor(v + 0.5)
end

--- A padding, gap, offset or border width as Clay holds it: whole uint16
-- pixels (clay.h:330-335, 344, 533-541). A fraction rounds silently; a
-- negative or oversized value is clamped with a warning.
function clay.pixels(who, property, v)
    v = clay.round(v or 0)
    if v < 0 then
        clay.ignore(who, property, "is negative and is 0")
        return 0
    elseif v > 65535 then
        clay.ignore(who, property, "exceeds 65535 and is 65535")
        return 65535
    end
    return v
end

--- The node a widget compiles to, plus any foreground it puts in force, or
-- nil for a hidden or refused widget. `node.specs` sizes its children.
-- A forced size overrides the size returned by the describer.
local function describe(w, fg, st)
    local record = w._clay

    if w._private.visible == false then return nil end
    local methods = {}
    for _, method in ipairs { "draw", "fit", "layout", "before_draw_children", "after_draw_children" } do
        if rawget(w, method) ~= nil then methods[#methods + 1] = ":" .. method end
    end
    if #methods > 0 or not record then
        local name = class_name(w) or "?"
        if not warned[name] then
            warned[name] = true
            local reason = #methods > 0 and "draws itself (" .. table.concat(methods, ", ") .. ")"
                or "has no describer"
            gdebug.print_warning("wibox.clay: " .. name .. " " .. reason .. " and is left out of the tree")
        end
        return nil
    end

    local node, node_fg = record.describe(w, fg, st)

    if node then
        node.w = w._private.forced_width or node.w
        node.h = w._private.forced_height or node.h
    end
    return node, node_fg
end

-- Resolve a shape's size from the offer before forced axes override it.
local function resolve_size(node, offer)
    for _, k in ipairs { "w", "h" } do
        if node[k .. "max"] == "offer" then
            node[k .. "max"] = offer[k]
        end
    end
    if node.aspect or node.square then
        local w = math.min(offer.w, node.wmax or math.huge)
        local h = math.min(offer.h, node.hmax or math.huge)
        local rw, rh

        if node.aspect then
            rw = math.ceil(math.min(w, h * node.aspect))
            rh = math.ceil(math.min(h, w / node.aspect))
        else
            rw, rh = math.min(w, h), math.min(w, h)
        end
        node.w = type(node.w) == "number" and node.w or rw
        node.h = type(node.h) == "number" and node.h or rh
    end
end

-- The node's box at most, and the offer its padding leaves for children.
-- Floating children take the full box (third_party/clay.h:2224-2237).
local function node_offer(node, offer)
    local box = {}

    for _, k in ipairs { "w", "h" } do
        local size = node[k]

        box[k] = math.min(type(size) == "number" and size
            or type(size) == "table" and offer[k] * size.percent or offer[k],
            node[k .. "max"] or math.huge)
    end
    local pad = node.pad or { 0, 0, 0, 0 }

    return { w = math.max(0, box.w - pad[1] - pad[2]),
        h = math.max(0, box.h - pad[3] - pad[4]) }, box
end

local compile_node

--- The nodes for a list of child specs: a widget's node with the sizing its
-- parent decided, or an empty element the parent asked for, which stands for
-- no widget and is left out of the box readback.
-- A node's own colors at the opacity its widget and ancestors compound to.
local function fade(node, alpha)
    for _, key in ipairs { "bg", "border", "fill", "stroke", "color" } do
        local color = node[key]
        if color and color[4] then color[4] = color[4] * alpha end
    end
    if node.fill and node.fill.stops then
        for _, stop in ipairs(node.fill.stops) do stop[5] = stop[5] * alpha end
    end
end

local function compile_specs(st, specs, parent, fg, offer, box, alpha)
    local nodes = {}

    for _, spec in ipairs(specs) do
        local node
        local bound = spec.float and box or offer

        resolve_size(spec, bound)
        local inner, spec_box = node_offer(spec, bound)

        if spec.widget then
            node = compile_node(st, spec.widget, parent, fg, spec_box, spec, alpha)
        else
            node = spec
            node.spacer = true
            -- An image leaf takes its place among the leaves, with no
            -- hierarchy to draw it: the renderer shows its surface.
            if spec.image then
                st.leaves[#st.leaves + 1] = { image = true, node = node }
            end
            node.children = spec.children
                and compile_specs(st, spec.children, parent, fg, inner, spec_box, alpha) or nil
            if alpha ~= 1 then fade(node, alpha) end
        end
        if node then nodes[#nodes + 1] = node end
    end
    return nodes
end

local sizing_keys = { "w", "h", "wmin", "hmin", "wmax", "hmax" }

local function same_sizing(a, b)
    for _, k in ipairs(sizing_keys) do
        local x, y = a[k], b[k]

        if x ~= y and not (type(x) == "table" and type(y) == "table"
                and x.percent == y.percent) then
            return false
        end
    end
    return true
end

-- Every widget the compile reaches, refused ones included, with its parent:
-- what the drawable wires, in preorder so a kept subtree can replay its own.
local function register(st, widget, parent)
    if st.widgets[widget] ~= nil then st.dup = true end
    st.widgets[widget] = parent
    st.regs[#st.regs + 1] = { widget, parent }
end

local function slice(list, from)
    local out = {}

    for i = from, #list do out[#out + 1] = list[i] end
    return out
end

--- The node tree for `widget`, sized as its parent's `spec` decided.
--
-- A widget's finished subtree depends on its own state, its offer, its
-- spec, its foreground and the opacity compounded down to it, and on
-- nothing of its siblings: compile_specs hands every child the same offer.
-- So a widget that no signal marked since the last compile keeps its
-- subtree when those inputs are equal, describers and all. The root is
-- always compiled, since every mark reaches it and the drawable's own
-- sizing is applied to its node.
function compile_node(st, widget, parent, fg, offer, spec, alpha)
    local cache = st.cache
    local entry = cache.entries[widget]

    alpha = alpha * (widget._private.opacity or 1)
    if entry and parent and not st.stale[widget] and st.widgets[widget] == nil
            and entry.fg == fg and entry.alpha == alpha
            and entry.offer.w == offer.w and entry.offer.h == offer.h
            and same_sizing(entry.spec, spec) then
        for _, reg in ipairs(entry.regs) do register(st, reg[1], reg[2]) end
        for _, leaf in ipairs(entry.leaves) do st.leaves[#st.leaves + 1] = leaf end
        return entry.node
    end

    local given, regs_from, leaves_from = offer, #st.regs + 1, #st.leaves + 1

    register(st, widget, parent or false)
    local node, node_fg = describe(widget, fg, st)

    if not node then
        cache.entries[widget] = nil
        return nil
    end

    if node.fit then
        offer = { w = node.wmax or 9999, h = node.hmax or 9999 }
    end
    resolve_size(node, offer)
    local inner, box = node_offer(node, offer)

    if node.share and #node.specs > 0 then
        local axis, count = node.share, #node.specs
        inner[axis] = math.max(0, (inner[axis] - (node.gap or 0) * (count - 1)) / count)
    end
    node.children = compile_specs(st, node.specs or {}, widget, node_fg or fg, inner, box, alpha)
    node.specs = nil
    node.class = class_name(widget)
    node.widget = widget
    merge_sizing(node, spec)
    if alpha ~= 1 then fade(node, alpha) end

    local sizing = {}
    for _, k in ipairs(sizing_keys) do sizing[k] = spec[k] end
    cache.entries[widget] = { node = node, fg = fg, alpha = alpha, offer = given,
        spec = sizing, regs = slice(st.regs, regs_from), leaves = slice(st.leaves, leaves_from) }
    return node
end

--- Mark `widget` as changed in `self`'s tree, up to the root: the next
-- compile describes those again and keeps every other subtree.
-- @tparam table self The drawable.
-- @tparam wibox.widget widget The widget that signalled.
-- @staticfct wibox.clay.invalidate
function clay.invalidate(self, widget)
    local cache = self._clay_cache

    if not cache then return end
    while widget do
        cache.stale[widget] = true
        widget = cache.parents[widget] or nil
    end
end

--- Add a wrapper class that passes through to one child: the widget under
-- `field` gets the whole box, so the node holds that child's spec. What
-- awful.widget.taglist and tasklist are around their `base_layout`; they
-- register here, since awful depends on wibox and not the other way.
--
-- @tparam table class The widget class.
-- @tparam string field The `_private` field holding the child.
-- @staticfct wibox.clay.passthrough
function clay.passthrough(class, field)
    class._clay = { describe = function(w)
        return { specs = whole_box(w._private[field]) }
    end }
end

--- Add a widget class with its describer, for a class defined outside
-- wibox (awful.widget's systray_icon). Instances must provide their
-- contents through this describer.
-- @tparam table class The widget class.
-- @tparam function describer The describer, as the class table's entries.
-- @staticfct wibox.clay.describe_class
function clay.describe_class(class, describer)
    class._clay = { describe = describer }
end

--- Compile a drawable's widget tree.
--
-- Returns the node tree, rooted at the drawable's own background, and the
-- image leaves in preorder. A missing or refused root leaves the drawable
-- background in the tree. Refused and hidden widgets remain connected to
-- property signals so a supported property value can restore their subtree.
--
-- A node is a table with any of `pad`, `bg`, `border`, `bw`, `radius`, the
-- sizing `w` and `h` (`"fit"` or absent, `"grow"`, or a fixed number) with
-- `wmin`, `hmin`, `wmax` and `hmax` as the floor and ceiling of fit and
-- grow, `dir` ("y" for top to bottom), `gap`,
-- `align` (`x` and `y`, as wibox.container.place names them), `float`
-- (attached to the parent's top left, off the flow), `spacer` for an element
-- that stands for no
-- widget, `class` (the widget's `widget_name`, for the `somewm-client clay
-- tree` dump), `widget`, and `children`. A text element is a node with
-- `text`, `font` (an id from `awesome._clay_font`), `color`, `wrap`,
-- `halign` and `ellipsize`, and nothing else; an image leaf is a node with
-- `image` (a cairo surface's native pointer) and its sizing. The compile
-- step resolves `aspect` and `square` into sizes. The C side ignores these
-- words and `widget`, which belong to the drawable.
--
-- @tparam table self The drawable, for its own background, background image
--  and foreground.
-- @tparam wibox.widget|nil root The drawable's widget.
-- @tparam table context The widget context.
-- @tparam number width The drawable's width, the root's offer.
-- @tparam number height The drawable's height.
-- @treturn[1] table The node tree.
-- @treturn[1] table The image leaves, in preorder.
function clay.compile(self, root, context, width, height)
    local base_rgba = solid_rgba(self.background_color)
    local fill = not base_rgba and clay.fill(self.background_color)
    if self.background_color and not base_rgba and not fill then
        clay.ignore("drawable", "bg", "is not a solid or a gradient and is transparent")
    end
    -- The kept subtrees, from the last compile of this context and size.
    -- A widget in the tree twice shares one entry, so such a tree is
    -- compiled whole every time.
    local cache = self._clay_cache
    if not cache or cache.context ~= context or cache.width ~= width
            or cache.height ~= height or cache.dup then
        cache = { context = context, width = width, height = height,
            entries = {}, stale = {}, parents = {} }
        self._clay_cache = cache
    end
    local st = { leaves = {}, widgets = {}, regs = {}, context = context,
        width = width, height = height, cache = cache, stale = cache.stale }
    cache.stale = {}
    local node = root and compile_node(st, root, nil, self.foreground_color,
        { w = width, h = height }, { w = "grow", h = "grow" }, 1)
    for w in pairs(cache.entries) do
        if st.widgets[w] == nil then cache.entries[w] = nil end
    end
    cache.parents, cache.dup = st.widgets, st.dup
    -- The widget gets the whole drawin, as the engine gave it. The root is
    -- the drawin's box, told (CLAY_SIZING_FIXED), unless the widget sizes
    -- the drawin (an awful.popup follows its content, `node.fit`): then
    -- the root wraps the widget (CLAY_SIZING_FIT) within the widget's
    -- limits, and the drawin takes the box Clay solves for it.
    local tree = { bg = base_rgba, radius = 0, class = "drawable",
        w = width, h = height, children = { node }, widgets = st.widgets }

    if node then
        if node.fit then
            tree.fit, node.fit = node.fit, nil
            tree.w, tree.h = "fit", "fit"
            tree.wmin, tree.wmax = node.wmin, node.wmax
            tree.hmin, tree.hmax = node.hmin, node.hmax
            node.wmin, node.wmax, node.hmin, node.hmax = nil, nil, nil, nil
        else
            -- A tree wider than its drawin lays out at its own size and is cut
            -- to the drawin, never squeezed into it: Clay compresses the
            -- children of a parent they overflow (clay.h:2300-2311), so the
            -- widget is a floating element, sized by its own content and
            -- clamped by nothing but its floor (clay.h:2224-2239), at least
            -- the drawin's box.
            node.float = true
            node.w, node.h = "fit", "fit"
            node.wmin = math.max(width, node.wmin or 0)
            node.hmin = math.max(height, node.hmin or 0)
        end
    end
    if self.background_image then
        if type(self.background_image) == "function" then
            clay.ignore("drawable", "bgimage", "is a function and is not drawn")
        else
            node = { image = self.background_image._native, class = "image", natural = true,
                w = "grow", h = "grow", spacer = true, children = { node } }
            table.insert(st.leaves, 1, { image = true, node = node })
        end
    end
    if fill then
        node = { shape = function(w, h) return clay.shape_ops(gshape.rectangle, w, h) end,
            fill = fill, w = "grow", h = "grow", spacer = true, children = { node } }
    end

    tree.children = { node }
    return tree, st.leaves
end

clay.solid_rgba = solid_rgba
clay.whole_box = whole_box

return clay

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
