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
local color = require("gears.color")
local object = require("gears.object")
local surface = require("gears.surface")
local protected_call = require("gears.protected_call")
local grect =  require("gears.geometry").rectangle
local wclay = require("wibox.clay")

local visible_drawables = {}

-- The drawables whose widgets changed since the frame last compiled them.
local pending = {}


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

    end
    return context
end

-- Widget changes compile the tree again. `widgets` includes refused widgets
-- so changing their properties can restore them, and maps each widget to its
-- parent for `emit_signal_recursive`.
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
-- both sides use, and collect the described widgets with their parents.
local function place_nodes(node, boxes, widgets, parent, k, index)
    index[#index + 1] = node
    if not node.spacer then
        k = k + 1
        node.box = boxes[k]
    end
    if node.widget then
        widgets[node.widget] = parent or false
        parent = node.widget
    end
    for _, child in ipairs(node.children or {}) do
        k = place_nodes(child, boxes, widgets, parent, k, index)
    end
    if node.solved then
        node.solved(node)
    end
    return k
end

-- The tree did not convert: nothing of it stays on this drawable.
local function unconvert(self)
    wire_widgets(self, {})
    self._clay_tree = nil
    self._clay_stored = nil
    return false
end

-- Compile the tree, hand it to the renderer and connect signals. The frame
-- solves it and sends the boxes back as clay::solved.
local function draw_converted(self, context, width, height)
    local tree = wclay.compile(self, self._widget, context, width, height)
    local stored, why = self.drawable:_clay_nodes(tree)

    if not stored then
        unconvert(self)
        return why ~= nil
    end
    self._clay_stored = { tree = tree, width = width, height = height }
    wire_widgets(self, tree.widgets)
    return true
end

-- The frame solved the stored tree: pair its nodes with their boxes.
local function place_solved(self, boxes)
    local stored = self._clay_stored

    if not stored then
        return
    end
    local tree, index = stored.tree, {}

    place_nodes(tree, boxes, tree.widgets, nil, 0, index)
    self._clay_tree = tree
    -- The tree's nodes in preorder, which is how the C side numbers them
    -- (widget.c read_tree), so a hit comes back as an index into this.
    self._clay_index = index
    -- A tree that sizes its drawin: the root's solved box is the size the
    -- drawin takes, as the engine applied a popup's fit after its layout.
    -- The resize marks the drawable again, and the same frame compiles and
    -- solves it at that size.
    if tree.fit and (tree.box.width ~= stored.width
            or tree.box.height ~= stored.height) then
        tree.fit(tree.box.width, tree.box.height)
    end
end

local function do_redraw(self)
    if not self.drawable.valid then
        return
    end
    if self._forced_screen and not self._forced_screen.valid then
        return
    end

    local success, geom = pcall(function() return self.drawable:geometry() end)
    if not success then return end
    draw_converted(self, get_widget_context(self), geom.width, geom.height)
end

-- The frame is about to declare: compile every drawable marked since the
-- last time. A compile that marks a drawable again (its own describer
-- changing a widget) lands in the next batch.
capi.awesome.connect_signal("clay::declare", function()
    local batch = pending

    pending = {}
    for self in pairs(batch) do
        protected_call(self._do_redraw)
    end
end)

-- The widgets of a converted tree under a point, outermost first: Clay's
-- pointer query against the output's last solve (drawable:_clay_hits), each
-- node named by its preorder index.
local function find_clay_widgets(self, result, x, y)
    for _, i in ipairs(self.drawable:_clay_hits(x, y)) do
        local node = self._clay_index[i]
        local box = node.box

        if node.widget then
            table.insert(result, {
                x = box.x, y = box.y, width = box.width, height = box.height,
                widget_width = box.width,
                widget_height = box.height,
                drawable = self,
                widget = node.widget,
            })
        end
    end
end

-- Find a widget by a point.
-- The drawable must have drawn itself at least once for this to work.
-- @param x X coordinate of the point
-- @param y Y coordinate of the point
-- @treturn table A table containing a description of all the widgets that
-- contain the given point. Each entry is a table containing this drawable as
-- its `.drawable` entry and the widget under `.widget`.
-- For convenience, `.x`, `.y`, `.width` and `.height` contain an
-- approximation of the widget's extents on the surface. `widget_width` and
-- `widget_height` contain the exact size of the widget in its own, local
-- coordinate system (which may e.g. be rotated and scaled).
function drawable:find_widgets(x, y)
    local result = {}
    if self._clay_tree then
        find_clay_widgets(self, result, x, y)
    end
    return result
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
-- Surface images are described under the root; function images are ignored.
-- @param image A background image or a function
function drawable:set_bgimage(image)
    -- Unset stays unset: gears.surface(nil) answers an empty default
    -- surface, which would keep the drawable a painter to the compile step
    -- (wibox.clay). awful.titlebar sets nil on every bar without an image.
    if image ~= nil and type(image) ~= "function" then
        image = surface(image)
    end

    self.background_image = image

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
    ret._clay_wired = {}
    setup_signals(ret)

    for k, v in pairs(drawable) do
        if type(v) == "function" then
            ret[k] = v
        end
    end

    -- Compile now: the frame's clay::declare, or an awful.popup sizing
    -- itself before any frame.
    ret._do_redraw = function()
        pending[ret] = nil
        do_redraw(ret)
    end

    -- A redraw marks the drawable for the next frame and asks for one.
    ret.draw = function()
        pending[ret] = true
        d:_clay_dirty()
    end
    ret._do_complete_repaint = function()
        ret:draw()
    end
    d:connect_signal("clay::solved", function(_, boxes) place_solved(ret, boxes) end)

    -- Geometry changes trigger a redraw.
    d:connect_signal("property::surface", ret.draw)

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
                v.widget:emit_signal(name, lx, ly, button, modifiers,v)
            end
        end)
    end
    button_signal("button::press")
    button_signal("button::release")

    d:connect_signal("mouse::move", function(_, x, y) handle_motion(ret, x, y) end)
    d:connect_signal("mouse::leave", function() handle_leave(ret) end)

    -- A converted widget's signals: a change compiles its subtree again.
    ret._clay_relayout = function(widget)
        wclay.invalidate(ret, widget)
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

-- When a screen's scale changes, every drawable recreates its surface at
-- the new scale: setting its geometry again is what makes the C side do so.
-- The visible drawables cover titlebars; root.drawins() covers every drawin,
-- shown or not.
-- A scale change moves the context's dpi, so every visible tree compiles
-- again with its fonts at the new size; a hidden drawable compiles when it
-- is shown.
screen.connect_signal("property::scale", draw_all)

return setmetatable(drawable, { __call = function(_, ...) return drawable.new(...) end })

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
