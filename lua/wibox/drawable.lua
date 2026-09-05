---------------------------------------------------------------------------
--- Handling of drawables. A drawable is something that can be drawn to.
--
-- @author Uli Schlachter
-- @copyright 2012 Uli Schlachter
-- @classmod wibox.drawable
---------------------------------------------------------------------------

local drawable = {}
local capi = {
    awesome = awesome,
    root = root,
    screen = screen
}
local beautiful = require("beautiful")
local base = require("wibox.widget.base")
local cairo = require("lgi").cairo
local color = require("gears.color")
local object = require("gears.object")
local surface = require("gears.surface")
local timer = require("gears.timer")
local grect =  require("gears.geometry").rectangle
local matrix = require("gears.matrix")
local whierarchy = require("wibox.hierarchy")
local wclay = require("wibox.clay")
local unpack = unpack or table.unpack -- luacheck: globals unpack (compatibility with Lua 5.1)

local visible_drawables = {}

local systray_widget

-- Get the widget context. This should always return the same table (if
-- possible), so that our draw and fit caches can work efficiently.
local function get_widget_context(self)
    local geom = self.drawable:geometry()

    local s = self._forced_screen
    if not s then
        local sgeos = {}

        for scr in capi.screen do
            sgeos[scr] = scr.geometry
        end

        s = grect.get_by_coord(sgeos, geom.x, geom.y) or capi.screen.primary
    end

    local context = self._widget_context
    local dpi = s and s.dpi or 96
    if (not context) or context.screen ~= s or context.dpi ~= dpi then
        context = {
            screen = s,
            dpi = dpi,
            drawable = self,
        }
        for k, v in pairs(self._widget_context_skeleton) do
            context[k] = v
        end
        self._widget_context = context

        -- Give widgets a chance to react to the new context
        self._need_complete_repaint = true
    end
    return context
end

-- Whether a leaf's box meets the dirty region, both in drawable
-- coordinates. The region's rectangles are read once per redraw, so this
-- costs no allocation per leaf.
local function touches(rects, box)
    for _, r in ipairs(rects) do
        if r[1] < box.x + box.width and box.x < r[1] + r[3]
                and r[2] < box.y + box.height and box.y < r[2] + r[4] then
            return true
        end
    end
    return false
end

-- The hierarchy that draws raster leaf i, laid out at the box Clay solved
-- for it. The layout engine survives only here, under a leaf: each leaf has
-- a `wibox.hierarchy` of its own, kept by the leaf's index in the tree as
-- its surface is (widget.c), placed on the drawable by its device matrix so
-- its dirty extents, its hit test and the mouse handlers that read
-- `find_widgets_result.hierarchy` all speak drawable coordinates.
local function leaf_hierarchy(self, i, leaf, context, dirty)
    local box = leaf.node.box
    local state = self._clay_leaves[i]

    if not state then
        state = {}
        state.hierarchy = whierarchy.new(context, leaf.widget,
            box.width, box.height, self._clay_leaf_redraw,
            self._clay_leaf_layout, state)
        self._clay_leaves[i] = state
    end
    state.hierarchy:update(context, leaf.widget, box.width, box.height,
        dirty, matrix.create_translate(box.x, box.y))
    return state.hierarchy
end

-- How many times a counted widget (wibox.hierarchy.count_widget) is placed
-- under the leaves, which is where the engine still places anything.
local function count_in_leaves(self, widget)
    local n = 0

    for _, state in ipairs(self._clay_leaves) do
        n = n + state.hierarchy:get_count(widget)
    end
    return n
end

-- Drop the leaf hierarchies past `keep`, and every one when the tree stops
-- converting: their widgets' signals reach this drawable through the whole
-- tree's hierarchy again, or through the leaves that stay.
local function drop_leaves(self, keep)
    for i = #self._clay_leaves, keep + 1, -1 do
        self._clay_leaves[i].dropped = true
        self._clay_leaves[i] = nil
    end
end

-- Paint the raster leaves into their own surfaces, only where the dirty
-- region touches them, so a clock tick re-rasters the clock and nothing
-- else. A surface new since it was last painted paints whole, wherever the
-- region reaches. A leaf's hierarchy draws from its own origin, which is the
-- surface's; the surfaces hold device pixels.
local function draw_leaves(self, context, leaves, scale, dirty)
    local rects, drawn = {}, {}

    for r = 0, dirty:num_rectangles() - 1 do
        local d = dirty:get_rectangle(r)

        rects[r + 1] = { d.x, d.y, d.width, d.height }
    end

    for i, leaf in ipairs(leaves) do
        local box = leaf.node.box
        -- A widget's own draw can make its drawin paint whole (it hosts
        -- the systray now, its opacity changed), which drops every leaf
        -- surface from under this loop. That flip asks for a complete
        -- repaint of its own, so stop and let it run.
        local native, fresh = self.drawable:_clay_leaf_surface(i)

        if not native then
            break
        end
        if fresh or touches(rects, box) then
            local lcr = cairo.Context(surface.load_silently(native, false))

            lcr:scale(scale, scale)
            if not fresh then
                for _, r in ipairs(rects) do
                    lcr:rectangle(r[1] - box.x, r[2] - box.y, r[3], r[4])
                end
                lcr:clip()
            end
            lcr.operator = cairo.Operator.SOURCE
            lcr:set_source_rgba(0, 0, 0, 0)
            lcr:paint()
            lcr.operator = cairo.Operator.OVER
            lcr:set_source(leaf.fg)
            self._clay_leaves[i].hierarchy:draw(context, lcr)
            drawn[i] = true
        end
    end
    self.drawable:_clay_leaves_drawn(drawn)
end

-- The signals `wibox.hierarchy` connects for the layout engine, connected
-- here for the widgets Clay solves instead: a change in any of them is a
-- change in the tree, so the tree compiles again. `widgets` maps each
-- widget in the tree to its parent, for `emit_signal_recursive`.
local function wire_widgets(self, widgets)
    local wired = self._clay_wired

    for w in pairs(wired) do
        if not widgets[w] then
            w:disconnect_signal("widget::redraw_needed", self._clay_relayout)
            w:disconnect_signal("widget::layout_changed", self._clay_relayout)
            w:disconnect_signal("widget::emit_recursive", self._clay_emit)
        end
    end
    for w in pairs(widgets) do
        if not wired[w] then
            w:weak_connect_signal("widget::redraw_needed", self._clay_relayout)
            w:weak_connect_signal("widget::layout_changed", self._clay_relayout)
            w:weak_connect_signal("widget::emit_recursive", self._clay_emit)
        end
    end
    self._clay_wired = widgets
end

-- Pair every widget node with the box Clay solved for it, in the preorder
-- both sides use, and collect the converted widgets with their parents. A
-- leaf's widget is its hierarchy's, which reaches the drawable on its own.
local function place_nodes(node, boxes, widgets, parent, k)
    if not node.spacer then
        k = k + 1
        node.box = boxes[k]
    end
    if node.widget and not node.raster then
        widgets[node.widget] = parent or false
        parent = node.widget
    end
    for _, child in ipairs(node.children or {}) do
        k = place_nodes(child, boxes, widgets, parent, k)
    end
    return k
end

-- Draw a converted tree: Clay solved every box, the leaves paint their own
-- surfaces at theirs, and the renderer draws the rest. Returns false when
-- the tree did not convert, in which case nothing here ran.
local function draw_converted(self, context, width, height, dirty)
    local tree, leaves = wclay.compile(self, self._widget, context, width, height)
    -- nil is not a tree: the renderer drops whatever it held and answers
    -- false, which is the whole of "paint it yourself".
    local scale, boxes = self.drawable:_clay_nodes(tree)

    if not scale then
        drop_leaves(self, 0)
        wire_widgets(self, {})
        self._clay_tree = nil
        return false
    end

    local widgets = {}

    place_nodes(tree, boxes, widgets, nil, 0)
    self._clay_tree = tree
    wire_widgets(self, widgets)
    -- The whole tree's hierarchy is the engine's; a converted tree has no
    -- use for it, and dropping it takes its signal connections with it.
    self._widget_hierarchy = nil
    self._widget_hierarchy_callback_arg = nil

    local had_systray = systray_widget and count_in_leaves(self, systray_widget) > 0

    for i, leaf in ipairs(leaves) do
        leaf_hierarchy(self, i, leaf, context, dirty)
    end
    drop_leaves(self, #leaves)
    if had_systray and count_in_leaves(self, systray_widget) == 0 then
        systray_widget:_kickout(context)
    end

    draw_leaves(self, context, leaves, scale, dirty)
    self.drawable:refresh()
    return true
end

local function do_redraw(self)
    if not self.drawable.valid then
        return
    end
    if self._forced_screen and not self._forced_screen.valid then
        return
    end

    local surf = surface.load_silently(self.drawable.surface, false)
    -- The surface can be nil if the drawable's parent was already finalized
    if not surf then
        return
    end
    local success, cr_or_err = pcall(function() return cairo.Context(surf) end)
    if not success then
        return
    end
    local cr = cr_or_err

    local success2, geom_or_err = pcall(function() return self.drawable:geometry() end)
    if not success2 then
        return
    end
    local geom = geom_or_err
    local x, y, width, height = geom.x, geom.y, geom.width, geom.height
    local context = get_widget_context(self)

    if self._need_complete_repaint then
        self._need_complete_repaint = false
        self._dirty_area:union_rectangle(cairo.RectangleInt{
            x = 0, y = 0, width = width, height = height
        })
    end

    -- Compile the widget tree into Clay declarations and solve it, before
    -- the engine lays anything out: the engine runs only under a raster
    -- leaf.
    local dirty = self._dirty_area

    self._dirty_area = cairo.Region.create()

    local converted = draw_converted(self, context, width, height, dirty)

    if converted then
        self._clay_converted = true
        return
    end
    -- This surface was never painted while the leaves were drawing, so
    -- leaving the converted path invalidates every pixel of it. (Entering
    -- it needs nothing: the leaves' surfaces are new, and paint whole.)
    if self._clay_converted then
        self._clay_converted = false
        dirty:union_rectangle(cairo.RectangleInt {
            x = 0, y = 0, width = width, height = height
        })
    end

    -- Relayout
    if self._widget_hierarchy and self._widget then
        local had_systray = systray_widget and self._widget_hierarchy:get_count(systray_widget) > 0

        self._widget_hierarchy:update(context,
            self._widget, width, height, dirty)

        local has_systray = systray_widget and self._widget_hierarchy:get_count(systray_widget) > 0
        if had_systray and not has_systray then
            systray_widget:_kickout(context)
        end
    elseif self._widget then
        self._widget_hierarchy_callback_arg = {}
        self._widget_hierarchy = whierarchy.new(context, self._widget, width, height,
                self._redraw_callback, self._layout_callback, self._widget_hierarchy_callback_arg)
        dirty:union_rectangle(cairo.RectangleInt{
            x = 0, y = 0, width = width, height = height
        })
    else
        self._widget_hierarchy = nil
    end

    if dirty:is_empty() then
        return
    end

    -- Clip to the dirty area
    for i = 0, dirty:num_rectangles() - 1 do
        local rect = dirty:get_rectangle(i)
        cr:rectangle(rect.x, rect.y, rect.width, rect.height)
    end
    cr:clip()

    -- Draw the background
    cr:save()

    if not capi.awesome.composite_manager_running then
        -- This is pseudo-transparency: We draw the wallpaper in the background
        local wallpaper = surface.load_silently(capi.root.wallpaper(), false)
        cr.operator = cairo.Operator.SOURCE
        if wallpaper then
            cr:set_source_surface(wallpaper, -x, -y)
        else
            cr:set_source_rgb(0, 0, 0)
        end
        cr:paint()
        cr.operator = cairo.Operator.OVER
        cr:set_source(self.background_color)
    else
        -- This is true transparency: We draw a translucent background
        cr.operator = cairo.Operator.SOURCE
        cr:set_source(self.background_color)
    end

    cr:paint()

    cr:restore()

    -- Paint the background image
    if self.background_image then
        cr:save()
        if type(self.background_image) == "function" then
            self.background_image(context, cr, width, height, unpack(self.background_image_args))
        else
            local pattern = cairo.Pattern.create_for_surface(self.background_image)
            cr:set_source(pattern)
            cr:paint()
        end
        cr:restore()
    end

    -- Draw the widget
    if self._widget_hierarchy then
        cr:set_source(self.foreground_color)
        self._widget_hierarchy:draw(context, cr)
    end

    self.drawable:refresh()

    assert(cr.status == "SUCCESS", "Cairo context entered error state: " .. cr.status)
end

local function find_widgets(self, result, hierarchy, x, y)
    local m = hierarchy:get_matrix_from_device()

    -- Is (x,y) inside of this hierarchy or any child (aka the draw extents)
    local x1, y1 = m:transform_point(x, y)
    local x2, y2, w2, h2 = hierarchy:get_draw_extents()
    if x1 < x2 or x1 >= x2 + w2 then
        return
    end
    if y1 < y2 or y1 >= y2 + h2 then
        return
    end

    -- Is (x,y) inside of this widget?
    local width, height = hierarchy:get_size()
    if x1 >= 0 and y1 >= 0 and x1 <= width and y1 <= height then
        -- Get the extents of this widget in the device space
        local x3, y3, w3, h3 = matrix.transform_rectangle(hierarchy:get_matrix_to_device(),
            0, 0, width, height)
        table.insert(result, {
            x = x3, y = y3, width = w3, height = h3,
            widget_width = width,
            widget_height = height,
            drawable = self,
            widget = hierarchy:get_widget(),
            hierarchy = hierarchy
        })
    end
    for _, child in ipairs(hierarchy:get_children()) do
        find_widgets(self, result, child, x, y)
    end
end

-- The widgets of a converted tree under a point, outermost first: the
-- preorder the tree was declared in, which is the order Clay_GetPointerOverIds
-- answers in (clay.h), each tested as Clay_PointerOver tests one element,
-- against the box Clay solved. A raster leaf hands over to the hierarchy
-- that draws it, which sits on the drawable at the leaf's box.
local function find_clay_widgets(self, result, node, x, y)
    local box = node.box

    if node.widget and x >= box.x and y >= box.y
            and x < box.x + box.width and y < box.y + box.height then
        if node.raster then
            return find_widgets(self, result,
                self._clay_leaves[node.leaf].hierarchy, x, y)
        end
        table.insert(result, {
            x = box.x, y = box.y, width = box.width, height = box.height,
            widget_width = box.width,
            widget_height = box.height,
            drawable = self,
            widget = node.widget,
        })
    end
    for _, child in ipairs(node.children or {}) do
        find_clay_widgets(self, result, child, x, y)
    end
end

-- Find a widget by a point.
-- The drawable must have drawn itself at least once for this to work.
-- @param x X coordinate of the point
-- @param y Y coordinate of the point
-- @treturn table A table containing a description of all the widgets that
-- contain the given point. Each entry is a table containing this drawable as
-- its `.drawable` entry, the widget under `.widget` and, for a widget the
-- layout engine placed, the instance of `wibox.hierarchy` describing the size
-- and position of the widget under `.hierarchy`; a widget Clay solved has no
-- hierarchy. For convenience, `.x`, `.y`, `.width` and `.height` contain an
-- approximation of the widget's extents on the surface. `widget_width` and
-- `widget_height` contain the exact size of the widget in its own, local
-- coordinate system (which may e.g. be rotated and scaled).
function drawable:find_widgets(x, y)
    local result = {}
    if self._clay_tree then
        find_clay_widgets(self, result, self._clay_tree, x, y)
    elseif self._widget_hierarchy then
        find_widgets(self, result, self._widget_hierarchy, x, y)
    end
    return result
end

-- Private API. Not documented on purpose.
function drawable._set_systray_widget(widget)
    whierarchy.count_widget(widget)
    systray_widget = widget
end

--- Set the widget that the drawable displays
function drawable:set_widget(widget)
    self._widget = base.make_widget_from_value(widget)

    -- Make sure the widget gets drawn
    self.draw()
end

function drawable:get_widget()
    return rawget(self, "_widget")
end

--- Set the background of the drawable
-- @param c The background to use. This must either be a cairo pattern object,
--   nil or a string that gears.color() understands.
-- @see gears.color
function drawable:set_bg(c)
    c = c or "#000000"
    local t = type(c)

    if t == "string" or t == "table" then
        c = color(c)
    end

    -- If the background is completely opaque, we don't need to redraw when
    -- the drawable is moved
    -- XXX: This isn't needed when awesome.composite_manager_running is true,
    -- but a compositing manager could stop/start and we'd have to properly
    -- handle this. So for now we choose the lazy approach.
    local redraw_on_move = not color.create_opaque_pattern(c)
    if self._redraw_on_move ~= redraw_on_move then
        self._redraw_on_move = redraw_on_move
        if redraw_on_move then
            self.drawable:connect_signal("property::x", self._do_complete_repaint)
            self.drawable:connect_signal("property::y", self._do_complete_repaint)
        else
            self.drawable:disconnect_signal("property::x", self._do_complete_repaint)
            self.drawable:disconnect_signal("property::y", self._do_complete_repaint)
        end
    end

    self.background_color = c
    self._do_complete_repaint()
end

--- Set the background image of the drawable
-- If `image` is a function, it will be called with `(context, cr, width, height)`
-- as arguments. Any other arguments passed to this method will be appended.
-- @param image A background image or a function
function drawable:set_bgimage(image, ...)
    if type(image) ~= "function" then
        image = surface(image)
    end

    self.background_image = image
    self.background_image_args = {...}

    self._do_complete_repaint()
end

--- Set the foreground of the drawable
-- @param c The foreground to use. This must either be a cairo pattern object,
--   nil or a string that gears.color() understands.
-- @see gears.color
function drawable:set_fg(c)
    c = c or "#FFFFFF"
    if type(c) == "string" or type(c) == "table" then
        c = color(c)
    end
    self.foreground_color = c
    self._do_complete_repaint()
end

function drawable:_force_screen(s)
    self._forced_screen = s
end

function drawable:_inform_visible(visible)
    self._visible = visible
    if visible then
        visible_drawables[self] = true
        -- The wallpaper or widgets might have changed
        self:_do_complete_repaint()
    else
        visible_drawables[self] = nil
    end
end

local function emit_difference(name, list, skip)
    local function in_table(table, val)
        for _, v in pairs(table) do
            if v.widget == val.widget then
                return true
            end
        end
        return false
    end

    for _, v in pairs(list) do
        if not in_table(skip, v) then
            v.widget:emit_signal(name,v)
        end
    end
end

local function handle_leave(self)
    emit_difference("mouse::leave", self._widgets_under_mouse, {})
    self._widgets_under_mouse = {}
end

local function handle_motion(self, x, y)
    local dgeo = self.drawable:geometry()

    if x < 0 or y < 0 or x > dgeo.width or y > dgeo.height then
        return handle_leave(self)
    end

    -- Build a plain list of all widgets on that point
    local widgets_list = self:find_widgets(x, y)

    -- First, "leave" all widgets that were left
    emit_difference("mouse::leave", self._widgets_under_mouse, widgets_list)
    -- Then enter some widgets
    emit_difference("mouse::enter", widgets_list, self._widgets_under_mouse)

    self._widgets_under_mouse = widgets_list
end

local function setup_signals(self)
    local d = self.drawable

    local function clone_signal(name)
        -- When "name" is emitted on wibox.drawin, also emit it on wibox
        d:connect_signal(name, function(_, ...)
            self:emit_signal(name, ...)
        end)
    end
    clone_signal("button::press")
    clone_signal("button::release")
    clone_signal("mouse::enter")
    clone_signal("mouse::leave")
    clone_signal("mouse::move")
    clone_signal("property::surface")
    clone_signal("property::width")
    clone_signal("property::height")
    clone_signal("property::x")
    clone_signal("property::y")
end

function drawable.new(d, widget_context_skeleton, drawable_name)
    local ret = object()
    ret.drawable = d
    ret._widget_context_skeleton = widget_context_skeleton
    ret._need_complete_repaint = true
    ret._dirty_area = cairo.Region.create()
    ret._clay_leaves = {}
    ret._clay_wired = {}
    ret._clay_converted = false
    setup_signals(ret)

    for k, v in pairs(drawable) do
        if type(v) == "function" then
            ret[k] = v
        end
    end

    -- Only redraw a drawable once, even when we get told to do so multiple times.
    ret._redraw_pending = false
    ret._do_redraw = function()
        ret._redraw_pending = false
        do_redraw(ret)
    end

    -- Connect our signal when we need a redraw
    ret.draw = function()
        if not ret._redraw_pending then
            timer.delayed_call(ret._do_redraw)
            ret._redraw_pending = true
        end
    end
    ret._do_complete_repaint = function()
        ret._need_complete_repaint = true
        ret:draw()
    end

    -- Do a full redraw if the surface changes (the new surface has no content yet)
    d:connect_signal("property::surface", ret._do_complete_repaint)

    -- Do a normal redraw when the drawable moves. This will likely do nothing
    -- in most cases, but it makes us do a complete repaint when we are moved to
    -- a different screen.
    d:connect_signal("property::x", ret.draw)
    d:connect_signal("property::y", ret.draw)

    -- Currently we aren't redrawing on move (signals not connected).
    -- :set_bg() will later recompute this.
    ret._redraw_on_move = false

    -- Set the default background
    ret:set_bg(beautiful.bg_normal)
    ret:set_fg(beautiful.fg_normal)

    -- Initialize internals
    ret._widgets_under_mouse = {}

    local function button_signal(name)
        d:connect_signal(name, function(_, x, y, button, modifiers)
            local widgets = ret:find_widgets(x, y)
            for _, v in pairs(widgets) do
                -- Calculate x/y inside of the widget
                local lx, ly = x - v.x, y - v.y
                if v.hierarchy then
                    lx, ly = v.hierarchy:get_matrix_from_device():transform_point(x, y)
                end
                v.widget:emit_signal(name, lx, ly, button, modifiers,v)
            end
        end)
    end
    button_signal("button::press")
    button_signal("button::release")

    d:connect_signal("mouse::move", function(_, x, y) handle_motion(ret, x, y) end)
    d:connect_signal("mouse::leave", function() handle_leave(ret) end)

    -- Set up our callbacks for repaints
    local function dirty_extents(hierar)
        local m = hierar:get_matrix_to_device()
        local x, y, width, height = matrix.transform_rectangle(m, hierar:get_draw_extents())
        local x1, y1 = math.floor(x), math.floor(y)
        local x2, y2 = math.ceil(x + width), math.ceil(y + height)
        ret._dirty_area:union_rectangle(cairo.RectangleInt{
            x = x1, y = y1, width = x2 - x1, height = y2 - y1
        })
        ret:draw()
    end
    ret._redraw_callback = function(hierar, arg)
        -- Avoid crashes when a drawable was partly finalized and dirty_area is broken.
        if not ret._visible then
            return
        end
        if ret._widget_hierarchy_callback_arg ~= arg then
            return
        end
        dirty_extents(hierar)
    end
    -- The same, for a raster leaf's own hierarchy, placed on the drawable
    -- at its box; a dropped leaf's widgets speak through another one.
    ret._clay_leaf_redraw = function(hierar, state)
        if ret._visible and not state.dropped then
            dirty_extents(hierar)
        end
    end
    ret._clay_leaf_layout = function(_, state)
        if ret._visible and not state.dropped then
            ret:draw()
        end
    end
    -- A converted widget's signals: any change compiles the tree again.
    ret._clay_relayout = function()
        if ret._visible then
            ret:draw()
        end
    end
    ret._clay_emit = function(widget, name, ...)
        while widget do
            widget:emit_signal(name, ...)
            widget = ret._clay_wired[widget] or nil
        end
    end
    ret._layout_callback = function(_, arg)
        if ret._widget_hierarchy_callback_arg ~= arg then
            return
        end
        -- When not visible, we will be redrawn when we become visible. In the
        -- mean-time, the layout does not matter much.
        if ret._visible then
            ret:draw()
        else
        end
    end

    -- Add __tostring method to metatable.
    ret.drawable_name = drawable_name or object.modulename(3)
    local mt = {}
    local orig_string = tostring(ret)
    mt.__tostring = function()
        return string.format("%s (%s)", ret.drawable_name, orig_string)
    end
    ret = setmetatable(ret, mt)

    -- Make sure the drawable is drawn at least once
    ret._do_complete_repaint()

    return setmetatable(ret, {
        __index = function(self, k)
            if rawget(self, "get_"..k) then
                return rawget(self, "get_"..k)(self)
            else
                return rawget(ret, k)
            end
        end,
        __newindex = function(self, k,v)
            if rawget(self, "set_"..k) then
                rawget(self, "set_"..k)(self, v)
            else
                rawset(self, k, v)
            end
        end
    })
end

-- Redraw all drawables when the wallpaper changes
capi.awesome.connect_signal("wallpaper_changed", function()
    for d in pairs(visible_drawables) do
        d:_do_complete_repaint()
    end
end)

-- Give drawables a chance to react to screen changes
local function draw_all()
    for d in pairs(visible_drawables) do
        d:draw()
    end
end
screen.connect_signal("property::geometry", draw_all)
screen.connect_signal("added", draw_all)
screen.connect_signal("removed", draw_all)

-- When screen scale changes, force all visible drawables to recreate their
-- surfaces at the new scale. This is done by re-setting their geometry,
-- which triggers the C-side scale detection and surface recreation.
screen.connect_signal("property::scale", function(s)
    -- Method 1: Iterate visible_drawables
    for d in pairs(visible_drawables) do
        local cd = d.drawable
        if cd and cd.surface then
            local geo = cd:geometry()
            if geo.width > 0 and geo.height > 0 then
                cd:geometry(geo)
            end
        end
    end

    -- Method 2: Also check screen's mywibox (wibar) if it exists
    if s.mywibox then
        local w = s.mywibox
        if w._drawable and w._drawable.drawable then
            local cd = w._drawable.drawable
            local geo = cd:geometry()
            if geo.width > 0 and geo.height > 0 then
                cd:geometry(geo)
            end
        end
    end

    -- Method 3: Check all drawins via root.drawins()
    local drawins = root.drawins and root.drawins()
    if drawins then
        for _, d in ipairs(drawins) do
            if d.drawable then
                local geo = d.drawable:geometry()
                if geo.width > 0 and geo.height > 0 then
                    d.drawable:geometry(geo)
                end
            end
        end
    end
end)

return setmetatable(drawable, { __call = function(_, ...) return drawable.new(...) end })

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
