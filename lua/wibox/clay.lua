---------------------------------------------------------------------------
--- Compile a drawable's widget tree into Clay declarations.
--
-- The declare pass (declare.c) draws a drawin from the tree this module
-- returns: locally compatible descriptions share elements, with every original
-- placement bound to its actual element. Image elements reference their own
-- surfaces. A widget that draws itself or has no describer is
-- refused together with its subtree; the drawable background remains.
--
-- The walk descends the widget tree and composes sizing declarations from
-- authored values. Clay solves their allocations and positions. A node's
-- sizing is one of the four
-- types clay.h names: `fit` wraps the content, which is Clay's default
-- (CLAY_SIZING_FIT), `grow` fills the parent (CLAY_SIZING_GROW), a number
-- is told (CLAY_SIZING_FIXED), and a table `{ percent = p }` is a share of
-- the parent (CLAY_SIZING_PERCENT, clay.h:66-72, 289-297). A container
-- says which of the first two each child gets; a widget's own preference (a
-- forced size, a place that fills) refines fit and never overrides grow,
-- since fit is the content size and that preference is the content. A
-- widget that declares grow itself takes what it is offered, and every box
-- up to the nearest decided size grows with it (takes_offer).
--
-- The authored bound (spec D045) starts with the drawin dimensions at the
-- root and reaches a node through FIXED sizes and filling GROW sizes, less
-- each padding on the way down; a FIT or PERCENT size leaves it undefined.
-- Clay measures text; an image declares its minimum from the bound and its
-- aspect, or its natural size where the bound is undefined. A cap of
-- `"offer"` (`wmax`, `hmax`) is the bound on that axis, for a node whose
-- content it cuts rather than outgrows. A described leaf gives its preferred
-- dimensions directly, using grow on an axis that takes the whole bound.
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
-- SOMEWM_CLAY_NO_CACHE=1 starts every compile from an empty fragment cache.
local no_cache = os.getenv("SOMEWM_CLAY_NO_CACHE") == "1"
local identities = setmetatable({}, {__mode = "k"})
local next_identity = 0
local next_occurrence = 0
-- Identity names the widget, not its box or position in a compiled subtree.
function clay.identity(widget)
    if not identities[widget] then
        next_identity = next_identity + 1
        identities[widget] = next_identity
    end
    return identities[widget]
end
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

-- Resolved once: a method looked up on the pattern goes through lgi's
-- element search, a string match per call.
local pattern_type, pattern_rgba = cairo.Pattern.get_type, cairo.SolidPattern.get_rgba

--- The straight-alpha components of a solid color pattern, or nil for a
-- gradient, a surface pattern, or no color at all. A solid color carries
-- four components (third_party/clay.h:223-225); the renderer uses straight alpha.
local function solid_rgba(col)
    if not col then
        return nil
    end

    local pattern = gcolor(col)

    if pattern_type(pattern) ~= "SOLID" then
        return nil
    end

    local status, r, g, b, a = pattern_rgba(pattern)

    if status ~= "SUCCESS" then
        return nil
    end

    return { r, g, b, a }
end

--- A solid fill or a linear or radial gradient in logical pixels, the
-- gradient's points moved by dx and dy.
function clay.fill(col, dx, dy)
    if not col then return nil end
    local pattern = gcolor(col)
    local kind = pattern_type(pattern)
    if kind == "SOLID" then return solid_rgba(col) end
    if kind ~= "LINEAR" and kind ~= "RADIAL" then return nil end
    local status, count = pattern:get_color_stop_count()
    if status ~= "SUCCESS" or count > 16 then return nil end
    local points = kind == "LINEAR" and { pattern:get_linear_points() }
        or { pattern:get_radial_circles() }
    if table.remove(points, 1) ~= "SUCCESS" then return nil end
    for i = 1, #points, kind == "LINEAR" and 2 or 3 do
        points[i], points[i + 1] = points[i] + (dx or 0), points[i + 1] + (dy or 0)
    end
    local fill = { stops = {} }
    fill[kind == "LINEAR" and "linear" or "radial"] = points
    for i = 0, count - 1 do
        local stop = { pattern:get_color_stop_rgba(i) }
        if table.remove(stop, 1) ~= "SUCCESS" then return nil end
        fill.stops[#fill.stops + 1] = stop
    end
    return fill
end

--- Put a fill record on a node that paints its colour as bg: a solid is
-- the bg, a gradient fills a shape of the node's own box at its radius.
function clay.bg_fill(node, fill)
    if fill and fill.stops then
        local radius = node.radius or 0
        node.fill = fill
        node.shape = function(width, height)
            return clay.shape_ops(gshape.rounded_rect, width, height, 0, 0, radius)
        end
    else
        node.bg = fill
    end
    return node
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
-- A number the parent gives carries the parent's source word. A grow on an
-- axis `parent_fit` names counts as fit (fit_grow).
local axes, floors, caps = {"w", "h"}, {"wmin", "hmin"}, {"wmax", "hmax"}
local function merge_sizing(node, spec, parent_fit)
    for i, k in ipairs(axes) do
        local src = k .. "src"
        local size = spec[k]
        if size == "grow" and (i == 1 and parent_fit % 2 == 1 or i == 2 and parent_fit >= 2) then
            size = "fit"
        end
        if spec.float or spec.stack then
            -- Overlaid children keep their own size, including the stack's
            -- in-flow content. An explicit manual allocation can enlarge it.
            if type(spec[k]) == "number" then
                local own = math.max(type(node[k]) == "number" and node[k] or 0,
                    node[k .. "min"] or 0)
                if spec[k] >= own then node[src] = spec[src] end
                node[k] = math.max(spec[k], own)
            else
                node[k] = node[k] or spec[k]
            end
        elseif size == "grow" then
            if type(node[k]) == "number" then
                node[k .. "min"] = node[k]
            end
            node[k] = "grow"
        elseif node[k] == nil then
            node[k] = size
            if size ~= nil and type(size) ~= "string" then node[src] = spec[src] end
        end
    end
    for _, k in ipairs(floors) do
        if spec[k] and (not node[k] or spec[k] >= node[k]) then
            node[k], node[k:sub(1, 1) .. "src"] = spec[k], spec[k:sub(1, 1) .. "src"]
        end
    end
    -- A cap from either side stands, and the tighter of two.
    for _, k in ipairs(caps) do
        if spec[k] and (not node[k] or spec[k] <= node[k]) then
            node[k], node[k:sub(1, 1) .. "src"] = spec[k], spec[k:sub(1, 1) .. "src"]
        end
    end
end

function clay.linear_spec(node, spec, spacing_widget, spacing, along, across)
    if spacing > 0 and spacing_widget and #node.specs > 0 then
        node.specs[#node.specs + 1] = { widget = spacing_widget, linear_spacing = true,
            [along] = spacing, [along .. "src"] = "user", [across] = "grow" }
    end
    node.specs[#node.specs + 1] = spec
end

local function icon_style(item)
    local config = beautiful.systray_icon_style
    if type(config) == "function" then
        local ok, value = pcall(config, item)
        if ok and type(value) == "table" then return value end
    elseif type(config) == "table" then
        return config[item.id] or config[item.app_name] or {}
    end
    return {}
end

--- wibox.widget.systray_icon centers the item's pixmap or icon file in
-- its authored slot, with status backgrounds and a floating overlay.
-- An icon without a usable pixmap or icon file is refused.
function clay.systray_icon(w)
    local p = w._private
    local item = p.item

    if not item then
        return clay.refuse(w, "icon", "has no pixmap and no icon file to draw")
    end
    local style = icon_style(item)
    local hover_scale = style.hover_scale or beautiful.systray_hover_scale or 1
    if p.is_hovered and hover_scale ~= 1 then
        clay.ignore(w, "hover_scale", "is not applied")
    end
    local hover_bg = style.hover_bg or beautiful.systray_hover_bg
    local overlay_urgent = style.overlay_triggers_urgent
    if overlay_urgent == nil then overlay_urgent = beautiful.systray_overlay_triggers_urgent end
    local urgent = item.status == "NeedsAttention" or item.overlay_icon and overlay_urgent
    local background = urgent and (style.urgent_bg or beautiful.systray_urgent_bg)
        or p.is_hovered and hover_bg

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

    local fill = clay.fill(background)
    if background and not fill then
        clay.ignore(w, urgent and "urgent_bg" or "hover_bg", "is not a solid or a gradient and is transparent")
    end
    local word = p.forced_size and "user" or "theme"
    local node = clay.bg_fill({ w = sw, h = sh, wsrc = word, hsrc = word,
        align = { x = "center", y = "center" },
        specs = { { image = surface, name = "image",
            aspect = iw / ih, image_width = iw, image_height = ih,
            wmax = sw, hmax = sh, wsrc = word, hsrc = word } } }, fill)
    if item.overlay_icon and beautiful.systray_show_overlay ~= false then
        local overlay_size = style.overlay_size or beautiful.systray_overlay_size or 0.33
        local extent = clay.round(overlay_size <= 1 and overlay_size * size or overlay_size)
        local overlay_bg = style.overlay_bg or beautiful.systray_overlay_bg
        local overlay_fill = clay.fill(overlay_bg)
        if overlay_bg and not overlay_fill then
            clay.ignore(w, "overlay_bg", "is not a solid or a gradient and is transparent")
        end
        local padding = overlay_fill and clay.pixels(w, "overlay_padding",
            style.overlay_padding or beautiful.systray_overlay_padding or 2) or 0
        local position = style.overlay_position or beautiful.systray_overlay_position or "bottom_right"
        local corner = ({top_left = 0, bottom_left = 2, top_right = 6, bottom_right = 8})[position] or 8
        local overlay_shape = style.overlay_shape or beautiful.systray_overlay_shape or "circle"
        node.specs[2] = clay.bg_fill({ float = true, parent = corner, own = corner,
            w = extent, h = extent, wsrc = "theme", hsrc = "theme",
            pad = {padding, padding, padding, padding},
            radius = overlay_fill and (overlay_shape == "circle" and extent / 2
                or overlay_shape == "rounded_rect" and extent / 4 or nil) or nil,
            children = { { image = item.overlay_icon, name = "image",
                w = "grow", h = "grow" } } }, overlay_fill)
    end
    return node
end

--- wibox.widget.systray -> the fixed layout it is, with the padding and
-- the background its overrides add (`beautiful.systray_paddings`,
-- `beautiful.bg_systray`) and the least size its `:fit` answers. More than
-- one row is drawn as one; a background that is not a solid or a gradient
-- is ignored. Padding and spacing round to uint16 pixels
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

    local along = p.dir == "y" and "h" or "w"

    -- Icons keep their own square and the tray centres them across its
    -- direction, in place of a grown slot around each one.
    local node = { dir = p.dir, gap = spacing > 0 and p.spacing_widget and 0 or spacing, specs = {},
        align = { [p.dir == "y" and "x" or "y"] = "center" },
        pad = { padding, padding, padding, padding },
        [along .. "min"] = padding * 2 + size,
        [along .. "src"] = w.base_size and "user" or "theme" }

    if beautiful.bg_systray then
        clay.bg_fill(node, clay.fill(beautiful.bg_systray))
        if not node.bg and not node.fill then
            clay.ignore(w, "bg_systray", "is not a solid or a gradient and is transparent")
        end
    end
    for _, child in ipairs(p.widgets) do
        clay.linear_spec(node, { widget = child }, p.spacing_widget, spacing,
            along, p.dir == "y" and "w" or "h")
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
-- `lua/`, and a config's modules live under `$XDG_CONFIG_HOME/somewm/`, so
-- the name arrives with the path still in front of it.
local config_dir = (require("gears.filesystem").get_xdg_config_home() .. "somewm/"):gsub("/", ".")
local function class_name(w)
    local name = w._clay and w._clay.name or w.widget_name

    if not name then
        return nil
    end
    local _, config_end = name:find(config_dir, 1, true)
    if config_end then name = name:sub(config_end + 1) end
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

--- Properties a class no longer has: setting one warns once that it is
-- ignored and changes nothing, and reading one answers nil.
function clay.retire(class, names)
    for _, name in ipairs(names) do
        class["set_" .. name] = function(w) clay.ignore(w, name, "is ignored") end
    end
end

--- A square widget's side and its word: on each axis its forced size or
-- the bound of its box, less `pad` (left, right, top, bottom); the smaller
-- of the axes that have one, nil when neither has.
function clay.square_side(w, bound, pad)
    local p, side, src = w._private
    pad = pad or {0, 0, 0, 0}
    for i, axis in ipairs {{"w", "forced_width"}, {"h", "forced_height"}} do
        local size, word = p[axis[2]], "user"
        if not size then size, word = bound[axis[1]], bound[axis[1] .. "src"] end
        if size then
            size = math.max(0, size - pad[2 * i - 1] - pad[2 * i])
            if not side or size < side then side, src = size, word end
        end
    end
    return side, src
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
local painters = { "draw", "fit", "layout", "before_draw_children", "after_draw_children" }

-- Where a painter method is defined, as `file:line` with the home directory
-- as `~`. Painters that share a name but come from different lines warn
-- separately.
local home = os.getenv("HOME")
local function defined_at(fn)
    if type(fn) ~= "function" then return "?" end
    local info = debug.getinfo(fn, "S")
    local file = info.source:sub(1, 1) == "@" and info.source:sub(2) or info.short_src
    if home and file:sub(1, #home + 1) == home .. "/" then file = "~" .. file:sub(#home + 1) end
    return file .. ":" .. info.linedefined
end

local function describe(w, fg, st, item, offer)
    local record = w._clay
    local field = w._private.animation
    local once = st.animation_once[w]
    if once == nil then
        once = require("wibox.widget.base").take_animation(w) or false
        st.animation_once[w] = once
    end
    local supported = {forced_width = true, forced_height = true}
    for property in pairs(record and record.animate_properties or {}) do supported[property] = true end
    if record and record.animate_value then supported.value = true end
    for _, settings in ipairs{type(field) == "table" and field or {}, once or {}} do
        for property in pairs(settings) do
            if not supported[property] then
                clay.ignore(w, "animation." .. property, "is unsupported; changes snap")
            end
        end
    end
    st.animation_policies[item] = {field = field, once = once or nil, off = item.animation_off, item = item}

    if w._private.visible == false then return nil end
    local methods
    for _, method in ipairs(painters) do
        if rawget(w, method) ~= nil then
            methods = methods or {}
            methods[#methods + 1] = ":" .. method
        end
    end
    if methods or not record then
        local name = class_name(w) or "?"
        local where = methods and defined_at(rawget(w, methods[1]:sub(2)))
        local key = name .. " " .. (where or "")
        if not warned[key] then
            warned[key] = true
            gdebug.print_warning("wibox.clay: " .. name .. (methods
                and " defines " .. table.concat(methods, ", ") .. " at " .. where
                    .. ", which 2.1 never calls. The widget and its children are left out of the tree."
                    .. " See https://somewm.org/docs/guides/custom-widgets"
                or " has no describer and is left out of the tree"))
        end
        return nil
    end

    local node, node_fg = record.describe(w, fg, st, item, offer)

    if node then
        local p = w._private
        if p.forced_width then node.w, node.wsrc = p.forced_width, "user" end
        if p.forced_height then node.h, node.hsrc = p.forced_height, "user" end
        local mapping = {forced_width = "width", forced_height = "height"}
        for property, word in pairs(record.animate_properties or {}) do
            local custom = property == "bg" and (node.fill or node.shape)
                or property ~= "bg" and node.stroke
            if custom then
                local policy = st.animation_policies[item]
                local setting = policy.once and policy.once[property]
                    or type(field) == "table" and field[property]
                if type(setting) == "number" then
                    clay.ignore(w, "animation." .. property, "uses a custom fill or stroke; changes snap")
                end
            else mapping[property] = word end
        end
        clay.animate(w, node, mapping, st, item)
    end
    return node, node_fg
end

function clay.animate(w, node, mapping, st, item)
    if not st then return end
    local policy = st.animation_policies[item]
    node.transition = require("somewm.animation").widget_word(w, mapping, policy)
end

local empty_list = {}
local no_padding = {0, 0, 0, 0}

-- An image declares one number, its minimum on the axis its parent lays out
-- along: the cross-axis bound or cap times its aspect, or its natural size
-- when the cross axis has neither, lowered to the flow-axis bound or cap
-- when that is smaller; never above a cap the describer gave and never
-- below its natural size when it may not shrink. The cross axis follows
-- from the aspect. A told axis and `image_resize = false` stay told.
local function size_image(node, bound, along)
    local nw, nh = node.image_width, node.image_height
    if not node.image or not node.aspect or node.aspect <= 0
            or not nw or not nh or nw <= 0 or nh <= 0 then return end
    if node.image_resize == false then
        node.w, node.h = nw, nh
    elseif type(node.w) ~= 'number' and type(node.h) ~= 'number' then
        local f, c = along, along == 'w' and 'h' or 'w'
        local natural = f == 'w' and nw or nh
        local size, src = natural, node[f .. 'src']
        local across, word = bound[c], bound[c .. 'src']
        if not across then across, word = bound[c .. 'cap'], bound[c .. 'capsrc'] end
        if across then
            size, src = f == 'w' and across * node.aspect or across / node.aspect, word
        end
        local cap, capword = bound[f], bound[f .. 'src']
        if not cap then cap, capword = bound[f .. 'cap'], bound[f .. 'capsrc'] end
        if cap and cap < size then size, src = cap, capword end
        if node[f .. 'max'] and node[f .. 'max'] < size then
            size, src = node[f .. 'max'], node[f .. 'src']
        end
        if node.image_downscale == false and size < natural then
            size, src = natural, node[f .. 'src']
        end
        node[f], node[f .. 'min'], node[f .. 'max'], node[f .. 'src'] = 'fit', size, nil, src
        node[c], node[c .. 'min'], node[c .. 'max'] = 'fit', nil, nil
    end
    node.image_resize, node.image_downscale = nil, nil
end

-- The scroll and overflow containers cap their content at the bound, with
-- the bound's word.
local function resolve_size(node, bound, along)
    for _, k in ipairs(axes) do
        if node[k .. "max"] == "offer" then
            node[k .. "max"], node[k .. "src"] = bound[k], bound[k .. "src"]
        end
    end
    size_image(node, bound, along)
end

local function padded(node)
    for _, value in ipairs(node.pad or empty_list) do
        if value ~= 0 then return true end
    end
    return false
end

local function painted(node)
    return (node.bg and node.bg[4] ~= 0)
        or (node.border and node.border[4] ~= 0) or node.image or node.shape
        or (node.radius or 0) > 0
end

-- A node with nothing in it, nothing on it and no extent along its parent's
-- flow: an empty textbox or imagebox, an empty list icon slot, an empty
-- tasklist. It has no layout, paint, input or attachment effect, and Clay
-- would still put a childGap on either side of it (clay.h:3080-3082), where
-- the engine skipped the spacing of a child whose `:fit` was zero. So it is
-- not declared. Its occurrence stays registered, so the widget still marks
-- its parent and a later value declares the element again.
--
-- Only the fields that stay harmless on an empty box are listed: a solid
-- colour has no pixels on a zero-area box. A ring, image, text, float,
-- share or an unknown field an ad-hoc
-- describer returned is a boundary, and keeps the element.
local inert_fields = {}
for _, key in ipairs {'w','h','wmin','hmin','wmax','hmax','pad','dir','gap',
        'align','children','name','widget','identity','occurrence','bindings',
        'spacer','owner','bg','radius','box','wgreedy','hgreedy'} do inert_fields[key] = true end

local function inert(node, along)
    if #(node.children or empty_list) ~= 0 or padded(node) or (node.radius or 0) > 0 then return false end
    for key in pairs(node) do
        if not inert_fields[key] then return false end
    end
    -- Along the flow it must take nothing: grow claims what is left over and
    -- a told size claims itself. Across it, grow only fills what its
    -- siblings already decided, so an empty box still spans nothing.
    local across = node[along == 'w' and 'h' or 'w'] or 'fit'

    if (node[along] or 'fit') ~= 'fit' or (across ~= 'fit' and across ~= 'grow') then
        return false
    end
    return (node.wmin or 0) == 0 and (node.hmin or 0) == 0
end

-- The authored bound (D045) of a node's box and what its padding leaves its
-- children: its own FIXED size, or the bound its parent gave its box;
-- nothing for a PERCENT size. Each number keeps the word of the size it came
-- from. `wdecided` and `hdecided` say whether the box is decided: by its own
-- FIXED size, or as its parent's allocation decided it. Without a bound, the
-- cap its parent gave its box (`wcap`, `hcap`) passes on the same way.
local function node_bound(node, box)
    local own, inner, pad = {}, {}, node.pad or no_padding
    for i, k in ipairs(axes) do
        local size, src = node[k], node[k .. 'src']
        own[k .. 'decided'] = type(size) == 'number' or box[k .. 'decided']
        inner[k .. 'decided'] = own[k .. 'decided']
        if type(size) ~= 'number' then
            size, src = type(size) ~= 'table' and box[k] or nil, box[k .. 'src']
        end
        if size then
            own[k], own[k .. 'src'] = size, src
            inner[k] = math.max(0, size - pad[2 * i - 1] - pad[2 * i])
            inner[k .. 'src'] = src
        elseif box[k .. 'cap'] then
            own[k .. 'cap'], own[k .. 'capsrc'] = box[k .. 'cap'], box[k .. 'capsrc']
            inner[k .. 'cap'] = math.max(0, box[k .. 'cap'] - pad[2 * i - 1] - pad[2 * i])
            inner[k .. 'capsrc'] = box[k .. 'capsrc']
        end
    end
    return inner, own
end

-- The bound of a child's box: its FIXED size, or its parent's bound when it
-- grows across its parent's flow, overlays it or is its only child, else
-- its parent's cap. A FIT child takes its parent's bound or cap as a cap
-- only: it may solve smaller (D045). A GROW child beside siblings on the
-- flow takes neither: its share is Clay's to solve. The box is decided
-- when Clay sizes it from the ancestors alone: FIXED, or GROW or PERCENT in
-- a decided parent. A FIT size follows its content (clay.h:2373,
-- 2387-2394).
local function spec_bound(spec, inner, along, only)
    local box = {}
    for _, k in ipairs(axes) do
        local size = spec[k]
        box[k .. 'decided'] = type(size) == 'number'
            or ((size == 'grow' or type(size) == 'table') and inner[k .. 'decided']) or nil
        if type(spec[k]) == 'number' then
            box[k], box[k .. 'src'] = spec[k], spec[k .. 'src']
        elseif spec[k] == 'grow' and (k ~= along or only or spec.float or spec.stack) then
            box[k], box[k .. 'src'] = inner[k], inner[k .. 'src']
            box[k .. 'cap'], box[k .. 'capsrc'] = inner[k .. 'cap'], inner[k .. 'capsrc']
        elseif (spec[k] or 'fit') == 'fit' then
            box[k .. 'cap'], box[k .. 'capsrc'] = inner[k] or inner[k .. 'cap'],
                inner[k .. (inner[k] and 'src' or 'capsrc')]
        end
    end
    return box
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

-- A sole child determines an unbounded-below FIT parent's content extent.
-- Its GROW axis can therefore remain FIT without changing either area.
-- Siblings and minimum extents retain their independent allocations.
local function fit_children(node, children)
    if #children ~= 1 or node.solved or node.scroll
            or node.image or node.aspect then return 0 end
    local w = (node.w or 'fit') == 'fit' and (node.wmin or 0) == 0
    local h = (node.h or 'fit') == 'fit' and (node.hmin or 0) == 0
    return (w and 1 or 0) + (h and 2 or 0)
end

local function fit_grow(node, parent_fit)
    if node.w == 'grow' and parent_fit % 2 == 1 and not node.wgreedy then node.w = 'fit' end
    if node.h == 'grow' and parent_fit >= 2 and not node.hgreedy then node.h = 'fit' end
end

-- A widget whose describer declared grow takes what it is offered on that
-- axis (wgreedy, hgreedy), as its `:fit` returned the offer: slider,
-- progressbar, separator, graph, piechart, manual, a place that fills.
-- Clay sizes a FIT or GROW box to its content (clay.h:1886-1940), where
-- such a widget counts nothing, so every box between it and the nearest
-- decided size grows on that axis too, as the engine's `:fit` passed the
-- offer up. A told or percent size stops it; a popup's content-sized root
-- takes its authored maximum (clay.compile).
local function takes_offer(node)
    for _, k in ipairs(axes) do
        local greedy = k .. 'greedy'
        if type(node[k]) == 'number' or type(node[k]) == 'table' then
            node[greedy] = nil
        else
            for _, child in ipairs(node.children or empty_list) do
                if child[greedy] and not child.float then node[greedy] = true end
            end
            if node[greedy] and not node.fit then node[k] = 'grow' end
        end
    end
end

-- Per transform: where the new x and y come from (the old axis, and whether
-- the map flips it), and which pad/bw sides of {left, right, top, bottom}
-- land on each side.
local transforms = {
    ["90"] = { turn = true, x = {"y", false}, y = {"x", true}, sides = {3, 4, 2, 1} },
    ["270"] = { turn = true, x = {"y", true}, y = {"x", false}, sides = {4, 3, 1, 2} },
    ["180"] = { x = {"x", true}, y = {"y", true}, sides = {2, 1, 4, 3} },
    ["flipped"] = { x = {"x", true}, y = {"y", false}, sides = {2, 1, 3, 4} },
    ["flipped-180"] = { x = {"x", false}, y = {"y", true}, sides = {1, 2, 4, 3} },
}
local align_steps = { left = 0, top = 0, center = 1, right = 2, bottom = 2 }
local align_words = { x = { [0] = "left", "center", "right" }, y = { [0] = "top", "center", "bottom" } }

-- Alignment steps (0 start, 1 center, 2 end) or offsets (negate) per axis.
local function axis_map(t, old, flip)
    local new = {}
    for _, axis in ipairs { "x", "y" } do
        local v = old[t[axis][1]]
        new[axis] = t[axis][2] and flip(v) or v
    end
    return new
end
local function flip_step(v) return 2 - v end
local function flip_offset(v) return -v end

-- A rotated or mirrored copy of a compiled subtree. The input is a cached
-- declaration, so every node is copied and none is written.
local function transformed(node, word, container)
    local t = transforms[word]
    local reversed = { [t.x[1]] = t.x[2], [t.y[1]] = t.y[2] }
    -- above names the nearest widget, which a scroll's own clip node is under.
    local function copy(n, above)
        above = n.name or above
        if n.transform then
            return clay.refuse(container, "widget", "holds a " .. (above or "widget")
                .. " that is already rotated or mirrored, and transforms do not nest")
        end
        if n.scroll then
            return clay.refuse(container, "widget", "holds a " .. (above or "scroll")
                .. ", and a scroll does not rotate")
        end
        if n.text and n.text:find("\n", 1, true) then
            return clay.refuse(container, "widget",
                "holds a textbox with more than one line, and a rotated run is one line")
        end
        local c = {}
        for key, value in pairs(n) do c[key] = value end
        c.transform = word
        if n.text then c.wrap = "none" end
        if t.turn then
            for _, pair in ipairs { {"w", "h"}, {"wmin", "hmin"}, {"wmax", "hmax"}, {"wsrc", "hsrc"},
                    {"wgreedy", "hgreedy"} } do
                c[pair[1]], c[pair[2]] = n[pair[2]], n[pair[1]]
            end
            if n.aspect then c.aspect = 1 / n.aspect end
            c.dir = n.dir == "y" and "x" or "y"
        end
        for _, key in ipairs { "pad", "bw" } do
            local v, s = n[key], t.sides
            if v then c[key] = { v[s[1]], v[s[2]], v[s[3]], v[s[4]] } end
        end
        local align = n.align or {}
        local a = axis_map(t, { x = align_steps[align.x or "left"],
            y = align_steps[align.y or "top"] }, flip_step)
        if n.align or a.x ~= 0 or a.y ~= 0 then
            c.align = { x = align_words.x[a.x], y = align_words.y[a.y] }
        end
        for _, key in ipairs { "parent", "own" } do
            if n[key] then
                local p = axis_map(t, { x = math.floor(n[key] / 3), y = n[key] % 3 }, flip_step)
                c[key] = p.x * 3 + p.y
            end
        end
        if n.x or n.y then
            local o = axis_map(t, { x = n.x or 0, y = n.y or 0 }, flip_offset)
            c.x, c.y = o.x, o.y
        end
        if n.children then
            local children, flow = {}, {}
            for i, child in ipairs(n.children) do
                children[i] = copy(child, above)
                if not children[i] then return nil end
                if not child.float then flow[#flow + 1] = i end
            end
            if reversed[n.dir == "y" and "y" or "x"] then
                for i = 1, math.floor(#flow / 2) do
                    local a, b = flow[i], flow[#flow + 1 - i]
                    children[a], children[b] = children[b], children[a]
                end
            end
            c.children = children
        end
        return c
    end
    return copy(node)
end

local function compile_specs(st, specs, parent, fg, bound, box, alpha, parent_fit, along, stack)
    local nodes = {}

    for _, spec in ipairs(specs) do
        if stack then
            spec.float = #nodes > 0 or nil
            if not spec.float then
                -- Native padding places the content. Floats still attach to
                -- the full stack box, with their original declaration offsets.
                stack.pad = {spec.x, 0, spec.y, 0}
                spec.x, spec.y = nil, nil
            end
        end
        local node
        local outer = spec.float and box or bound

        resolve_size(spec, outer, along)
        local spec_box = spec_bound(spec, outer, along, #specs == 1 or stack)

        if spec.widget then
            local child_box, child_along, child_fit = spec_box, along, parent_fit
            if transforms[spec.transform] and transforms[spec.transform].turn then
                -- The child is compiled in its own frame, where the axes are exchanged.
                child_box = {}
                for key, value in pairs(spec_box) do
                    child_box[(key:gsub("^[wh]", { w = "h", h = "w" }))] = value
                end
                child_along = along == "w" and "h" or "w"
                child_fit = (parent_fit % 2) * 2 + math.floor(parent_fit / 2)
            end
            node = compile_node(st, spec.widget, parent, fg, child_box, spec, alpha,
                spec.float and 0 or child_fit, child_along)
            if node and spec.transform then node = transformed(node, spec.transform, parent.widget) end
        else
            node = spec
            node.spacer = true
            fit_grow(node, spec.float and 0 or parent_fit)
            local inner, own = node_bound(spec, spec_box)
            node.children = spec.children
                and compile_specs(st, spec.children, parent, fg, inner, own, alpha,
                    fit_children(node, spec.children), spec.dir == "y" and "h" or "w") or nil
            takes_offer(node)
            if alpha ~= 1 then fade(node, alpha) end
        end
        if node and not inert(node, along) then
            nodes[#nodes + 1] = node
            if stack and stack.top_only then break end
        end
    end
    return nodes
end

local spec_keys = { "w", "h", "wmin", "hmin", "wmax", "hmax",
    "float", "stack", "x", "y", "parent", "own", "passthrough", "_attach" }

local function same_spec(a, b)
    for _, k in ipairs(spec_keys) do
        local x, y = a[k], b[k]

        if x ~= y and not (type(x) == "table" and type(y) == "table"
                and x.percent == y.percent) then
            return false
        end
    end
    return true
end

-- A placement belongs to its original Lua parent, independently of the Clay
-- elements that represent it. Repeated references occupy separate slots;
-- inserting an unrelated sibling does not renumber either slot.
local function occurrence(st, widget, parent)
    local building = st.building[parent]
    local slots = building.slots[widget]
    if not slots then slots = {}; building.slots[widget] = slots end
    local previous = parent.slots[widget]
    local item = previous and previous[#slots + 1]
    if not item then
        next_occurrence = next_occurrence + 1
        assert(next_occurrence < 4294967296, 'widget occurrence IDs exhausted')
        item = {id = next_occurrence, identity = clay.identity(widget), widget = widget, parent = parent,
            slots = {}, children = {}}
        item.bindings = {item = item}
    end
    slots[#slots + 1] = item
    building.children[#building.children + 1] = item
    return item
end

local function finish_children(st, item, building)
    if #item.children ~= #building.children then
        st.membership_changed = true
    else
        for i, child in ipairs(building.children) do
            if item.children[i] ~= child then st.membership_changed = true; break end
        end
    end
    item.slots, item.children = building.slots, building.children
end

-- Binding lists share their tails with cached fragments. Folding a chain
-- prepends one occurrence at each level, without copying its descendants.
local function next_binding(first, previous)
    local list = first
    if previous then list = previous.next end
    if list then return list, list.item end
end

function clay.bindings(node)
    return next_binding, node.bindings
end

-- This local rule only combines boxes whose equality follows directly from
-- the declarations. A child's cap/floor, floating placement or a parent's
-- inset can give it a different area and therefore keeps its real element.
-- Unknown declaration fields are conservative boundaries for ad-hoc widgets.
-- `box` is solve readback metadata on cached nodes, not a sizing input.
local fold_fields = {}
for _, key in ipairs {'w','h','wmin','hmin','wmax','hmax','pad','bg','border','bw',
        'radius','dir','gap','align','children','name','widget','identity',
        'occurrence','bindings','spacer','owner','box','wsrc','hsrc','transition',
        'wgreedy','hgreedy'} do fold_fields[key] = true end

-- An opaque rectangular child completely covers a plain background at the
-- same area. Keeping only that child's paint preserves source-over order,
-- including translucent ancestors. Rounded edges and borders keep their
-- independent paint/clip scopes; translucent layers are never flattened.
local function covers_background(node, child)
    return node.bg and not node.border and (node.radius or 0) == 0
        and child.bg and child.bg[4] == 1 and (child.radius or 0) == 0
end

local function same_axis(node, child, axis, host)
    local outer, inner = node[axis] or 'fit', child[axis] or 'fit'
    local floor, cap = child[axis .. 'min'] or 0, child[axis .. 'max'] or 0
    if host and inner == 'grow' and floor == 0 and cap == 0 then
        -- The root widget requests the host allocation. Keep overflow on its
        -- original descendants and keep the host's passive clip, rather than
        -- inserting an unbounded GROW layout between that clip and content.
        return true
    end
    -- A content-sized root stays FIT: a FIXED drawin root is the drawin's
    -- geometry, so an authored child keeps its own element.
    if host and outer == 'fit' and type(inner) == 'number' then return false end
    if type(outer) == 'number' then
        -- The definite drawable root carries a passive clip, which also
        -- prevents compression of its immediate children. Moving a layout
        -- into that root would change its children's allocation policy.
        if #(child.children or empty_list) ~= 0 then return false end
        if type(inner) == 'number' then return inner == outer end
        -- A bounded GROW child fills this exact allocation. An unbounded
        -- container may overflow through its descendants' intrinsic minima,
        -- so only an empty leaf can prove the same fact without a cap.
        return inner == 'grow' and floor <= outer
            and (cap == outer or (cap == 0 and not padded(child)))
    end
    if outer == 'fit' and inner == 'fit'
            and (node[axis .. 'min'] or 0) == 0
            and (node[axis .. 'max'] or 0) == 0 then return true end
    if floor ~= 0 or cap ~= 0 or type(outer) ~= 'string'
            or (node[axis .. 'max'] or 0) ~= 0
            or (inner == 'fit' and (node[axis .. 'min'] or 0) ~= 0) then
        return false
    end
    if outer == 'fit' and type(inner) == 'number'
            and (node[axis .. 'min'] or 0) == 0 then return true end
    return inner == 'grow' or (outer == 'fit' and inner == 'fit')
end

-- Concatenate immutable binding chains: repeated folds must retain every
-- original widget, including contributions already absorbed by the parent.
local function join_bindings(prefix, tail)
    if not prefix then return tail end
    return {item = prefix.item, next = join_bindings(prefix.next, tail)}
end

local extents, paints = {'w','h','wmin','hmin','wmax','hmax'}, {'bg','border','bw','radius'}
local function size_transition(node)
    local word = node.transition
    if not word then return false end
    for _, property in ipairs(type(word.properties) == "table" and word.properties or {word.properties}) do
        if property == "width" or property == "height" or property == "size" or property == "box" then return true end
    end
    return false
end

local function combine(node, opaque_host, host)
    if #(node.children or empty_list) == 0 or padded(node) then return node end
    local child = node.children[1]
    for i = 2, #node.children do
        if not node.children[i].float then return node end
    end
    for key in pairs(node) do
        if not fold_fields[key] then return node end
    end
    for key in pairs(child) do
        if not fold_fields[key] then return node end
    end
    if size_transition(node) or size_transition(child) then return node end
    if node.transition and child.transition then return node end
    local covered = opaque_host and covers_background(node, child)
    if covered and node.transition then return node end
    if painted(node) and painted(child) and not covered then return node end
    for _, axis in ipairs(axes) do
        if not same_axis(node, child, axis, host) then return node end
    end
    -- The result owns its fields; neither the child's cached declaration nor
    -- its shared binding tail is mutated by a different parent occurrence.
    local result = {}
    for key, value in pairs(child) do result[key] = value end
    result.transition = node.transition or child.transition
    result.wgreedy, result.hgreedy = node.wgreedy or child.wgreedy, node.hgreedy or child.hgreedy
    if #node.children > 1 then
        result.children = {}
        for _, grandchild in ipairs(child.children or empty_list) do
            result.children[#result.children + 1] = grandchild
        end
        for i = 2, #node.children do
            result.children[#result.children + 1] = node.children[i]
        end
    end
    for _, key in ipairs(extents) do
        local from = node
        if (key == 'w' or key == 'h') and (node[key] or 'fit') == 'fit'
                and type(child[key]) == 'number' then
            from = child
        elseif key ~= 'w' and key ~= 'h' and node[key] == nil
                and (node[key:sub(1,1)] or 'fit') == 'fit' then
            from = child
        end
        result[key] = from[key]
        if from == node and type(node[key]) ~= 'string' and node[key] ~= nil then
            result[key:sub(1, 1) .. 'src'] = node[key:sub(1, 1) .. 'src']
        end
    end
    if painted(node) and not covered then
        for _, key in ipairs(paints) do result[key] = node[key] end
    end
    -- The inner object names the shared element, since it is the one that
    -- stays as wrappers around it come and go. A list is the exception: it
    -- is the object the config holds and its base layout is its own, so it
    -- keeps the name. Both placements stay in the bindings below.
    if node.owner or (node.widget and (painted(node) or node.radius ~= nil))
            or not child.occurrence then
        result.name, result.identity, result.occurrence = node.name, node.identity, node.occurrence
    end
    result.widget, result.spacer = node.widget, nil
    result.bindings = join_bindings(node.bindings, child.bindings)
    return result
end

-- An image may own an original widget's area only when both declared axes
-- guarantee equality. In particular, a fixed image inside a GROW widget
-- keeps that widget's larger input area, even if today's boxes coincide.
local image_fields = {}
for key in pairs(fold_fields) do image_fields[key] = true end
for _, key in ipairs {'image', 'vector', 'natural', 'aspect', 'image_width', 'image_height'} do
    image_fields[key] = true
end

-- The image fills an authored slot when its minimum is the slot on its axis
-- and the slot has the image's aspect. A different aspect or a cap leaves
-- space around the image and keeps its container.
local function image_fills(node, child)
    if type(node.w) ~= 'number' or type(node.h) ~= 'number' or not child.aspect
            or (child.w or 'fit') ~= 'fit' or (child.h or 'fit') ~= 'fit'
            or child.wmax or child.hmax or node.h * child.aspect ~= node.w then
        return false
    end
    return child.wmin == node.w or child.hmin == node.h
end

local function combine_image(node)
    if #(node.children or empty_list) ~= 1 or padded(node) or painted(node) then return node end
    local child = node.children[1]
    if not child.image or #(child.children or empty_list) ~= 0 then return node end
    for key in pairs(node) do
        if not fold_fields[key] then return node end
    end
    for key in pairs(child) do
        if not image_fields[key] then return node end
    end
    local sizes = {}
    for _, axis in ipairs(axes) do
        if (node[axis .. 'min'] or 0) ~= 0 or (node[axis .. 'max'] or 0) ~= 0 then return node end
    end
    if image_fills(node, child) then
        sizes.w, sizes.h = node.w, node.h
    else
        for _, axis in ipairs(axes) do
            local outer, inner = node[axis] or 'fit', child[axis] or 'fit'
            if type(inner) == 'number' and (outer == 'fit' or outer == inner) then
                sizes[axis] = inner
            elseif inner == 'fit' and outer == 'fit' then
                sizes[axis] = 'fit'
            elseif inner == 'grow' and not child.aspect
                    and (child[axis .. 'min'] or 0) == 0
                    and (child[axis .. 'max'] or 0) == 0 then
                sizes[axis] = outer
            else
                return node
            end
        end
    end
    local result = {}
    for key, value in pairs(child) do result[key] = value end
    result.w, result.h = sizes.w, sizes.h
    for _, axis in ipairs(axes) do
        if type(sizes[axis]) == 'number' and sizes[axis] == node[axis] then
            result[axis .. 'src'] = node[axis .. 'src']
        end
    end
    result.widget, result.spacer = node.widget, nil
    if not child.occurrence then
        result.identity, result.occurrence = node.identity, node.occurrence
    end
    result.bindings = join_bindings(node.bindings, child.bindings)
    return result
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
function compile_node(st, widget, parent, fg, offer, spec, alpha, parent_fit, along)
    local cache = st.cache
    local item = occurrence(st, widget, parent)
    local entry = cache.entries[item]

    item.animation_off = parent.animation_off or widget._private.animation == false
    alpha = alpha * (widget._private.opacity or 1)
    if entry and parent.widget and not st.stale[item]
            and entry.fg == fg and entry.alpha == alpha
            and entry.animation_off == item.animation_off
            and entry.parent_fit == parent_fit
            and entry.offer.w == offer.w and entry.offer.h == offer.h
            and entry.offer.wsrc == offer.wsrc and entry.offer.hsrc == offer.hsrc
            and entry.offer.wdecided == offer.wdecided and entry.offer.hdecided == offer.hdecided
            and entry.offer.wcap == offer.wcap and entry.offer.hcap == offer.hcap
            and entry.offer.wcapsrc == offer.wcapsrc and entry.offer.hcapsrc == offer.hcapsrc
            and same_spec(entry.spec, spec) then
        st.reused = st.reused + 1
        return entry.node
    end

    assert(not st.active[widget], 'cycle in widget declarations')
    st.active[widget] = true
    local building = {slots = {}, children = {}}
    st.building[item] = building
    local given = offer

    st.compiled = st.compiled + 1
    local node, node_fg = describe(widget, fg, st, item, offer)

    if not node then
        cache.entries[item] = nil
        finish_children(st, item, building)
        st.active[widget] = nil
        return nil
    end

    if node.fit then offer = {} end
    resolve_size(node, offer, along)
    local intrinsic_w, intrinsic_h = node.w, node.h
    node.wgreedy, node.hgreedy = intrinsic_w == 'grow' or nil, intrinsic_h == 'grow' or nil
    local inner, box = node_bound(node, offer)
    merge_sizing(node, spec, parent_fit)
    fit_grow(node, parent_fit)
    if node.fit then node.w, node.h = 'fit', 'fit' end

    node.children = compile_specs(st, node.specs or empty_list, item, node_fg or fg, inner, box, alpha,
        fit_children(node, node.stack and {true} or node.specs or empty_list),
        node.dir == "y" and "h" or "w", node.stack and node)
    takes_offer(node)
    if not node.stack and #node.children == 1 then
        local child = node.children[1]
        local fitting = fit_children(node, node.children)
        if fitting ~= 0 and #(node.specs or empty_list) > 1 and not child.float then
            local copy = {}
            for key, value in pairs(child) do copy[key] = value end
            fit_grow(copy, fitting)
            node.children[1] = copy
        end
    end
    node.specs = nil
    local empty = node.stack and #node.children == 0
    node.stack, node.top_only = nil, nil
    if spec.stack and not empty then
        -- Test participation before the stack's default GROW allocation can
        -- turn an empty layout into a spacer. Painted backgrounds participate
        -- because a stack gives even childless backgrounds its whole box.
        local w, h = node.w, node.h
        node.w, node.h = intrinsic_w, intrinsic_h
        empty = inert(node, "w") and not (node.bg and node.bg[4] ~= 0)
        node.w, node.h = w, h
    end
    if empty then
        cache.entries[item] = nil
        finish_children(st, item, building)
        st.active[widget] = nil
        return nil
    end
    local private = rawget(widget, "_private")
    node.name = private and private.declarative_id or class_name(widget) or "widget"
    node.widget = widget
    node.identity = item.identity
    node.occurrence = item.id
    node.bindings = item.bindings
    if alpha ~= 1 then fade(node, alpha) end
    if parent.widget then node = combine_image(node) end
    node = combine(node, st.opaque_host)
    local fitting = fit_children(node, node.children or empty_list)
    if fitting ~= 0 and node.children[1] and not node.children[1].float then
        local child = node.children[1]
        if (child.w == 'grow' and fitting % 2 == 1)
                or (child.h == 'grow' and fitting >= 2) then
            local copy = {}
            for key, value in pairs(child) do copy[key] = value end
            fit_grow(copy, fitting)
            node.children = {copy}
        end
    end
    if spec.float then
        node.float = true
        node._attach = spec._attach
        node.x, node.y = spec.x or node.x, spec.y or node.y
        node.parent, node.own = spec.parent or node.parent, spec.own or node.own
        if spec.passthrough ~= nil then node.passthrough = spec.passthrough end
    end

    -- A recompiled occurrence refills its entry.
    if not entry then
        entry = { spec = {} }
        cache.entries[item] = entry
    end
    entry.animation_off = item.animation_off
    entry.node, entry.fg, entry.alpha, entry.offer, entry.parent_fit = node, fg, alpha, given, parent_fit
    for _, k in ipairs(spec_keys) do entry.spec[k] = spec[k] end
    finish_children(st, item, building)
    st.active[widget] = nil
    return node
end

--- Mark `widget` as changed in `self`'s tree, up to the root: the next
-- compile describes those again; other subtrees retain their cached nodes.
-- @tparam table self The drawable.
-- @tparam wibox.widget widget The widget that signalled.
-- @staticfct wibox.clay.invalidate
function clay.invalidate(self, widget)
    local cache = self._clay_cache

    if not cache then return end
    for _, item in ipairs(cache.widgets[widget] or {}) do
        while item and item.widget do
            cache.stale[item] = true
            item = item.parent
        end
    end
end

-- Commit geometry and binding targets before invoking public solved callbacks.
function clay._publish(self, tree, boxes)
    -- The index is refilled in place: a new tree rarely changes its length.
    local index, n, callbacks, scrolled, k = self._clay_index or {}, 0, {}, {}, 0
    -- above is the nearest widget above node.
    local function place(node, above)
        n = n + 1
        index[n] = node
        if not node.text and not node.client and (not node.spacer or node.scroll) then
            k = k + 1
            node.box = boxes[k]
            node.id = node.box and node.box.id
            if node.scroll and above and node.box and node.box.scrolled then
                scrolled[#scrolled + 1] = { above, node.box.scrolled }
            end
        end
        for _, binding in clay.bindings(node) do binding.element = node end
        -- A client composite publishes nothing (declare.c widget_boxes_walk).
        for _, child in ipairs(not node.client and node.children or empty_list) do
            place(child, node.widget or above)
        end
        if node.solved then callbacks[#callbacks + 1] = node end
    end
    place(tree)
    for i = #index, n + 1, -1 do index[i] = nil end
    self._clay_tree, self._clay_index = tree, index
    local protected_call = require('gears.protected_call')
    for _, node in ipairs(callbacks) do protected_call(node.solved, node) end
    for _, pair in ipairs(scrolled) do pair[1]:emit_signal("clay::scrolled", pair[2]) end
end

-- Enumerate the original placements once, including hidden/refused widgets
-- that must still invalidate their parent. Cached fragments do not contain
-- copies of all descendant registrations or image lists.
local function collect_occurrences(item, widgets, used)
    used[item] = true
    local list = widgets[item.widget]
    if not list then list = {}; widgets[item.widget] = list end
    list[#list + 1] = item
    for _, child in ipairs(item.children) do collect_occurrences(child, widgets, used) end
end

local function collect_leaves(node, leaves)
    if node.image then leaves[#leaves + 1] = {image = true, node = node} end
    for _, child in ipairs(node.children or empty_list) do collect_leaves(child, leaves) end
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
        return { specs = whole_box(w._private[field]), owner = true }
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
-- (off the flow), `x`/`y` offsets, `parent`/`own` attachment points (0-8,
-- top left by default), `passthrough` (true by default), `spacer` for an element
-- that stands for no
-- widget, `name` (the declarative id or full widget class name, shared by
-- the element id and tree dumps), `widget`, and `children`. Original placements use immutable
-- shared-tail `bindings` lists, enumerated with clay.bindings(node). A text element is a node with
-- `text`, `font` (an id from `awesome._clay_font`), `color`, `wrap`,
-- `halign` and `ellipsize`. A textbox container owns its sizing, alignment
-- and original bindings; its anonymous text child has no published box.
-- An image leaf is a node with
-- `image` (a cairo surface's native pointer) and its sizing. The compile
-- step declares its minimum from `aspect`, `image_width` and `image_height`.
--
-- @tparam table self The drawable, for its own background, background image
--  and foreground.
-- @tparam wibox.widget|nil root The drawable's widget.
-- @tparam table context The widget context.
-- @tparam number width The drawable's width, the root's bound.
-- @tparam number height The drawable's height.
-- @tparam table|nil words The words of that box, `{w = word, h = word}`.
-- @treturn[1] table The node tree.
-- @treturn[1] table The image leaves, in preorder.
function clay.compile(self, root, context, width, height, words)
    local opaque_host = not self.drawable or self.drawable._clay_opaque ~= false
    local base_rgba = solid_rgba(self.background_color)
    local fill = not base_rgba and clay.fill(self.background_color)
    if self.background_color and not base_rgba and not fill then
        clay.ignore("drawable", "bg", "is not a solid or a gradient and is transparent")
    end
    -- The kept subtrees, from the last compile of this context and size.
    -- Entries belong to occurrences, so repeated objects retain independent
    -- fragments. Context changes discard fragments but preserve placement IDs.
    local cache = self._clay_cache
    if no_cache or not cache or cache.context ~= context or cache.width ~= width
            or cache.height ~= height or cache.opaque_host ~= opaque_host then
        cache = { context = context, width = width, height = height,
            entries = {}, stale = {}, widgets = {}, opaque_host = opaque_host }
        self._clay_cache = cache
    end
    local owner = self._clay_occurrence_root
    if not owner then
        owner = {slots = {}, children = {}}
        self._clay_occurrence_root = owner
    end
    local building = {slots = {}, children = {}}
    local st = { building = {[owner] = building}, compiled = 0, reused = 0,
        active = {}, animation_policies = {}, animation_once = {}, context = context, opaque_host = opaque_host,
        cache = cache, stale = cache.stale,
        drawable = self.drawable }
    cache.stale = {}
    local bound = {}
    if not self._attachment_fit then
        -- A stretched bar's length is the output's (drawin.c:91): the drawin
        -- holds no authored number on that axis and its tree receives none.
        local size = { w = width, h = height }
        bound.wdecided, bound.hdecided = true, true
        for _, k in ipairs(axes) do
            local word = words and words[k]
            if word ~= "output" then bound[k], bound[k .. "src"] = size[k], word end
        end
    end
    local node = root and compile_node(st, root, owner, self.foreground_color, bound,
        { w = "grow", h = "grow" }, 1, self._attachment_fit and 3 or 0, "w")
    finish_children(st, owner, building)
    if st.membership_changed or not next(cache.widgets) then
        local widgets, used = {}, {}
        for _, item in ipairs(owner.children) do collect_occurrences(item, widgets, used) end
        for item in pairs(cache.entries) do
            if not used[item] then cache.entries[item] = nil end
        end
        cache.widgets = widgets
    end
    st.leaves = {}
    -- The widget gets the whole drawin, as the engine gave it. The root is
    -- the drawin's box, told (CLAY_SIZING_FIXED), unless the widget sizes
    -- the drawin (an awful.popup follows its content, `node.fit`): then
    -- the root wraps the widget (CLAY_SIZING_FIT) within the widget's
    -- limits, and the drawin takes the box Clay solves for it.
    local tree = { bg = base_rgba, radius = 0, name = "drawable",
        w = width, h = height, children = { node } }

    if node then
        if node.fit or self._attachment_fit then
            node.fit = nil
            tree.w, tree.h = "fit", "fit"
            tree.wmin, tree.wmax = node.wmin, node.wmax
            tree.hmin, tree.hmax = node.hmin, node.hmax
            tree.wsrc, tree.hsrc = node.wsrc, node.hsrc
            -- Content that takes its offer takes the authored maximum.
            if node.wgreedy and tree.wmax then tree.wmin = tree.wmax end
            if node.hgreedy and tree.hmax then tree.hmin = tree.hmax end
            node.wmin, node.wmax, node.hmin, node.hmax = nil, nil, nil, nil
            -- Positive host minima make the content fill the whole axis.
            node.w = (tree.wmin or 0) > 0 and 'grow'
                or type(node.w) == 'number' and node.w or 'fit'
            node.h = (tree.hmin or 0) > 0 and 'grow'
                or type(node.h) == 'number' and node.h or 'fit'
            node = combine(node, opaque_host)
        end
        node = combine_image(node)
        collect_leaves(node, st.leaves)
    end
    if self.background_image then
        node = { image = self.background_image._native, name = "image", natural = true,
            w = "grow", h = "grow", spacer = true, children = { node } }
        table.insert(st.leaves, 1, { image = true, node = node })
    end
    if fill then
        node = { shape = function(w, h) return clay.shape_ops(gshape.rectangle, w, h) end,
            fill = fill, w = "grow", h = "grow", spacer = true, children = { node } }
    end

    tree.children = { node }
    -- An anonymous content-sized host follows the same local area rules as
    -- a widget parent. Its registry is metadata, outside that contribution.
    -- Definite hosts share only provably equal allocations. Incompatible
    -- bounds/paint and potentially overflowing content retain their boundary.
    tree = combine(tree, opaque_host, true)
    tree.widgets = cache.widgets
    tree.compiled, tree.reused = st.compiled, st.reused
    return tree, st.leaves
end

clay.solid_rgba = solid_rgba
clay.whole_box = whole_box

return clay

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
