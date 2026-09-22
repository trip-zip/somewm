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
local pending_empty = setmetatable({}, {__mode="k"})


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
-- so changing their properties can restore them. Each object maps to its
-- original occurrences; the shorter Clay tree does not define Lua parents.
local function wire_widgets(self, widgets)
    local wired = self._clay_wired
    if widgets == wired then return end

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

-- The tree did not convert: nothing of it stays on this drawable.
local function unconvert(self)
    wire_widgets(self, {})
    self._clay_tree = nil
    self._clay_stored = nil
    return false
end

capi.awesome.connect_signal("clay::_commit", function(s)
    for self in pairs(pending_empty) do
        if get_widget_context(self).screen == s then
            unconvert(self)
            self._clay_offer = nil
            pending_empty[self] = nil
        end
    end
end)

-- Compile the tree, hand it to the renderer and connect signals. The frame
-- solves it and sends the boxes back as clay::solved.
local function draw_converted(self, context, width, height)
    local tree = wclay.compile(self, self._widget, context, width, height)
    local stored, why = self.drawable:_clay_nodes(tree)

    if not stored then
        self._clay_stored = { tree = false, context = context }
        pending_empty[self] = true
        return why ~= nil
    end
    pending_empty[self] = nil
    self._clay_stored = { tree = tree, width = width, height = height, context = context }
    local wired = {}
    for widget, occurrences in pairs(self._clay_tree and self._clay_tree.widgets or {}) do wired[widget] = occurrences end
    for widget, occurrences in pairs(tree.widgets) do wired[widget] = occurrences end
    wire_widgets(self, wired)
    return true
end

-- The frame solved the stored tree: pair its nodes with their boxes.
local function place_solved(self, boxes)
    local stored = self._clay_stored

    if not stored then
        return
    end
    if not stored.tree then unconvert(self); return end
    wclay._publish(self, stored.tree, boxes)
    wire_widgets(self, stored.tree.widgets)
    self._clay_offer = nil
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
    draw_converted(self, get_widget_context(self),
        self._clay_offer and self._clay_offer.width or geom.width,
        self._clay_offer and self._clay_offer.height or geom.height)
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

        for _, binding in wclay.bindings(node) do
            table.insert(result, {
                x = box.x, y = box.y, width = box.width, height = box.height,
                widget_width = box.width,
                widget_height = box.height,
                drawable = self,
                widget = binding.widget,
                occurrence = binding.id,
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

-- The host output is attachment input, independent of the widget's solved box.
function drawable:get_screen()
    return get_widget_context(self).screen
end

-- Select identity metadata only. No position is inferred from an old box.
-- A caller with an event token bypasses this lookup; a programmatic target
-- must name one visible original placement, optionally within a given host.
function drawable._clay_target(widget, host)
    local owner
    local function visit(candidate)
        local cache = candidate._clay_cache
        for _, item in ipairs(cache and cache.widgets[widget] or {}) do
            local entry = cache.entries[item]
            if entry and entry.node then
                assert(not owner, 'ambiguous attachment target; pass a widget hit with its occurrence')
                owner = candidate
            end
        end
    end
    if host then
        if host._visible then visit(host) end
    else
        for candidate in pairs(visible_drawables) do visit(candidate) end
    end
    return owner
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
            if v.occurrence == val.occurrence then
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

    -- Compile the pending inputs at the frame's clay::declare boundary.
    ret._do_redraw = function()
        pending[ret] = nil
        do_redraw(ret)
    end

    -- A redraw marks the drawable for the next frame and asks for one.
    ret.draw = function()
        ret._clay_offer = nil
        pending[ret] = true
        d:_clay_dirty()
    end
    ret._clay_compile = function() pending[ret] = true end
    ret._do_complete_repaint = function()
        ret:draw()
    end
    d:connect_signal("clay::_settle", function(_, boxes, offer)
        local stored = ret._clay_stored
        if stored and stored.tree then
            wclay._settle(stored.tree, boxes)
            if offer.width ~= stored.width or offer.height ~= stored.height then
                ret._clay_offer = offer
                ret._clay_compile()
                d:_clay_grid_pending()
            end
        end
    end)
    d:connect_signal("clay::solved", function(_, boxes) place_solved(ret, boxes) end)

    -- Geometry changes trigger a redraw.
    d:connect_signal("property::surface", ret.draw)
    d:connect_signal("property::_clay_opaque", ret.draw)

    -- A move changes compilation only when it changes the screen or dpi.
    local function context_changed()
        local stored = ret._clay_stored
        if stored and get_widget_context(ret) ~= stored.context then
            ret.draw()
        end
    end
    d:connect_signal("property::x", context_changed)
    d:connect_signal("property::y", context_changed)

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
        -- Preserve emit_signal_recursive's documented once-per-upward-path
        -- delivery when an object has several original placements.
        for _, item in ipairs(ret._clay_wired[widget] or {}) do
            while item and item.widget do
                item.widget:emit_signal(name, ...)
                item = item.parent
            end
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
