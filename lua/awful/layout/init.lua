---------------------------------------------------------------------------
--- Deterministically lay the clients in a screen workarea.
--
-- The `awful.layout` module contains many sub-modules. Each of them contain
-- one or more layout. `awful.layout` offers static layouts rather than
-- tree based like other WMs. The layout have a small number of configuration
-- variables:
--
-- * `master_width_factor`: The ratio between the main (master) section of the
--  layout and a sub-section. For example, in the `tile.left` layout, the main
--  (master) part contains `master_count` clients and the secondary part contains
--  all other clients.
-- * `master_count`: The number of clients which belong to the main (master) area.
-- * `column_count`: The number of columns to store the clients in the secondary
--   area.
-- * `master_fill_policy`: When the number of clients is below `master_count`,
--  how is the remaining space used.
-- * `gaps`: The empty space between the clients.
-- * `gap_single_client`: Same as gap, but when there is a single client. Gaps
--  are often useful as a visual cue to know where a client starts and ends.
--  This makes no sense when there is only one.
--
-- Not all layouts make use of all variables. Having such an overloaded meaning
-- to a small set of variable is useful to attach those values to keybindings
-- without having special logic for each layouts. AwesomeWM keybindings are not
-- modal, so such "limitation" actually improves usability.
--
-- @author Julien Danjou &lt;julien@danjou.info&gt;
-- @copyright 2008 Julien Danjou
-- @module awful.layout
---------------------------------------------------------------------------

-- Grab environment we need
local ipairs = ipairs
local type = type
local capi = {
    screen = screen,
    mouse  = mouse,
    awesome = awesome,
    client = client,
    tag = tag
}
local tag = require("awful.tag")
local client = require("awful.client")
local ascreen = require("awful.screen")
local timer = require("gears.timer")
local gmath = require("gears.math")
local gtable = require("gears.table")
local gdebug = require("gears.debug")
local protected_call = require("gears.protected_call")

local function get_screen(s)
    return s and capi.screen[s]
end

local layout = {}

-- Support `table.insert()` to avoid breaking old code.
local default_layouts = setmetatable({}, {
    __newindex = function(self, key, value)
        assert(key <= #self+1 and key > 0)

        layout.append_default_layout(value)
    end
})


layout.suit = require("awful.layout.suit")

--- The default list of layouts.
--
-- The default value is:
--
--    awful.layout.suit.floating,
--    awful.layout.suit.tile,
--    awful.layout.suit.tile.left,
--    awful.layout.suit.tile.bottom,
--    awful.layout.suit.tile.top,
--    awful.layout.suit.fair,
--    awful.layout.suit.fair.horizontal,
--    awful.layout.suit.spiral,
--    awful.layout.suit.spiral.dwindle,
--    awful.layout.suit.max,
--    awful.layout.suit.max.fullscreen,
--    awful.layout.suit.magnifier,
--    awful.layout.suit.corner.nw,
--    awful.layout.suit.corner.ne,
--    awful.layout.suit.corner.sw,
--    awful.layout.suit.corner.se,
--
-- @field awful.layout.layouts

--- Return the tag layout index (from `awful.layout.layouts`).
--
-- If the layout isn't part of `awful.layout.layouts`, this function returns
-- nil.
--
-- @tparam tag t The tag.
-- @treturn nil|number The layout index.
-- @staticfct awful.layout.get_tag_layout_index
function layout.get_tag_layout_index(t)
    return gtable.hasitem(layout.layouts, t.layout)
end

-- This is a special lock used by the arrange function.
-- This avoids recurring call by emitted signals.
local arrange_lock = false
-- Delay one arrange call per screen.
local delayed_arrange = {}

-- Screens whose layout describes at the next frame's clay::declare, and per
-- screen the table it described, which the solve publishes boxes onto.
local pending_describe = {}
local described = setmetatable({}, {__mode = "k"})

--- Get the current layout.
-- @tparam screen screen The screen.
-- @return The layout function.
-- @staticfct awful.layout.get
function layout.get(screen)
    screen = screen or capi.mouse.screen

    if not screen then return nil end

    local t = get_screen(screen).selected_tag
    return tag.getproperty(t, "layout") or layout.suit.floating
end

--- Change the layout of the current tag.
-- @tparam integer i Relative index.
-- @tparam screen s The screen.
-- @tparam[opt=s.selected_tag.layouts] table layouts A table of layouts.
-- @noreturn
-- @staticfct awful.layout.inc
function layout.inc(i, s, layouts)
    if type(i) == "table" then
        layouts, i, s = i, s, layouts
    end
    s = get_screen(s or ascreen.focused())
    local t = s.selected_tag

    if not t then return end

    layouts = layouts or t.layouts or {}

    if #layouts == 0 then
        layouts = layout.layouts
    end

    local cur_l = layout.get(s)

    -- First try to match the object
    local cur_idx =  gtable.find_first_key(
        layouts, function(_, v) return v == cur_l or cur_l._type == v end, true
    )

    -- Safety net: handle cases where another reference of the layout
    -- might be given (e.g. when (accidentally) cloning it).
    cur_idx = cur_idx or gtable.find_first_key(
        layouts, function(_, v) return v.name == cur_l.name end, true
    )

    -- Trying to come up with some kind of fallback layouts to iterate would
    -- never produce a result the user expect, so if there is nothing to
    -- iterate over, do not iterate.
    if not cur_idx then return end

    local newindex = gmath.cycle(#layouts, cur_idx + i)
    layout.set(layouts[newindex], t)
end

--- Set the layout function of the current tag.
-- @tparam layout|function l Layout object or function.
-- @tparam[opt=mouse.screen.selected_tag] tag t The tag to modify.
-- @noreturn
-- @staticfct awful.layout.set
function layout.set(l, t)
    t = t or capi.mouse.screen.selected_tag
    t.layout = l
end

--- Get the layout parameters used for the screen
--
-- This should give the same result as "arrange", but without the "geometries"
-- parameter, as this is computed during arranging.
--
-- If `t` is given, `screen` is ignored, if none are given, the mouse screen is
-- used.
--
-- @tparam[opt] tag t The tag to query
-- @param[opt] screen The screen
-- @treturn table A table with the workarea (x, y, width, height), the screen
--   geometry (x, y, width, height), the clients, the screen and sometime, a
--   "geometries" table with client as keys and geometry as value
-- @staticfct awful.layout.parameters
function layout.parameters(t, screen)
    screen = get_screen(screen)
    t = t or screen.selected_tag

    screen = get_screen(t and t.screen or 1)

    local p = {}

    local clients           = client.tiled(screen)
    local gap_single_client = true

    if(t and t.gap_single_client ~= nil) then
        gap_single_client = t.gap_single_client
    end

    local useless_gap = 0
    if t then
        local skip_gap = layout.get(screen).skip_gap or function(nclients)
            return nclients < 2
        end
        if gap_single_client or not skip_gap(#clients, t) then
            useless_gap = t.gap
        end
    end

    p.workarea = screen:get_bounding_geometry {
        honor_padding  = true,
        honor_workarea = true,
        margins        = useless_gap,
    }

    p.geometry    = screen.geometry
    p.clients     = clients
    p.screen      = screen.index
    p.padding     = screen.padding
    p.useless_gap = useless_gap

    return p
end

-- The arrange layout.arrange queues for a screen: the delayed call runs it,
-- or the frame's clay::declare first when the frame comes before it.
local function run_arrange(screen)
    if not screen.valid then
        -- Screen was removed
        delayed_arrange[screen] = nil
        return
    end
    if arrange_lock then return end
    arrange_lock = true

    -- protected call to ensure that arrange_lock will be reset
    protected_call(function()
        -- The next frame's clay::declare describes the screen; a screen
        -- with neither a tree nor a client asks for that frame only to
        -- drop what it described.
        local current = layout.get(screen)
        pending_describe[screen] = true
        if current._clay or described[screen] or #screen.clients > 0 then
            capi.awesome._clay_dirty()
        end
        if current._clay then return end
        local p = layout.parameters(nil, screen)

        local useless_gap = p.useless_gap

        p.geometries = setmetatable({}, {__mode = "k"})
        layout.get(screen).arrange(p)

        for c, g in pairs(p.geometries) do
            g.width = math.max(1, g.width - c.border_width * 2 - useless_gap * 2)
            g.height = math.max(1, g.height - c.border_width * 2 - useless_gap * 2)
            g.x = g.x + useless_gap
            g.y = g.y + useless_gap
            c:geometry(g)
        end
    end)
    arrange_lock = false
    delayed_arrange[screen] = nil

    screen:emit_signal("arrange")
end

--- Arrange a screen using its current layout.
-- @tparam screen screen The screen to arrange.
-- @noreturn
-- @staticfct awful.layout.arrange
function layout.arrange(screen, geometry_only)
    screen = get_screen(screen)
    if not screen or delayed_arrange[screen] then
        return
    end
    if geometry_only and layout.get(screen)._clay then
        local published = true
        for _, c in ipairs(screen.clients) do
            if not c:_clay_geometry_is_solved() then
                published = false
                break
            end
        end
        if published then return end
    end
    delayed_arrange[screen] = true

    timer.delayed_call(function()
        if delayed_arrange[screen] then run_arrange(screen) end
    end)
end

--- Append a layout to the list of default tag layouts.
--
-- @staticfct awful.layout.append_default_layout
-- @tparam layout to_add A valid tag layout.
-- @noreturn
-- @see awful.layout.layouts
function layout.append_default_layout(to_add)
    rawset(default_layouts, #default_layouts+1, to_add)
    capi.tag.emit_signal("property::layouts")
end

--- Remove a layout from the list of default layouts.
--
-- @DOC_text_awful_layout_remove_EXAMPLE@
--
-- @staticfct awful.layout.remove_default_layout
-- @tparam layout to_remove A valid tag layout.
-- @treturn boolean True if the layout was found and removed.
-- @see awful.layout.layouts
function layout.remove_default_layout(to_remove)
    local ret, found = false, true

    -- Remove all instances, just in case.
    while found do
        found = false
        for k, l in ipairs(default_layouts) do
            if l == to_remove then
                table.remove(default_layouts, k)
                ret, found = true, true
                break
            end
        end
    end

    return ret
end

--- Append many layouts to the list of default tag layouts.
--
-- @staticfct awful.layout.append_default_layouts
-- @tparam table layouts A table of valid tag layout.
-- @noreturn
-- @see awful.layout.layouts
function layout.append_default_layouts(layouts)
    for _, l in ipairs(layouts) do
        rawset(default_layouts, #default_layouts+1, l)
    end
end

--- Get the current layout name.
-- @param _layout The layout.
-- @return The layout name.
-- @staticfct awful.layout.getname
function layout.getname(_layout)
    _layout = _layout or layout.get()
    return _layout.name
end

-- A suite's {client = c} leaves become client composites; a composite
-- already has children. Every client the tree took is marked in taken. A
-- leaf placed at x or y and sized on the same axis is taken and left out.
local describe_client = require("awful.client.clay").describe
local slot_warned = setmetatable({}, {__mode = "k"})
local refused_warned = setmetatable({}, {__mode = "k"})
local function expand(node, taken)
    if node.client then
        taken[node.client] = true
        if (node.x ~= nil and type(node.w) ~= "number")
                or (node.y ~= nil and type(node.h) ~= "number") then
            if not slot_warned[node.client] then
                slot_warned[node.client] = true
                gdebug.print_warning("awful.layout: client " ..
                    (node.client.class or node.client.name or "?") ..
                    " is placed at x,y and sized on the same axis, and is left out of the tree")
            end
            return nil
        end
        return node.children and node or describe_client(node.client, node)
    end
    if node.children then
        local children = {}
        for _, child in ipairs(node.children) do children[#children + 1] = expand(child, taken) end
        node.children = children
    end
    return node
end

-- A visible client the suite did not take floats at its own box, attached
-- to the screen: the output's box when fullscreen, else its geometry plus
-- the border, which lies right of and below the geometry origin.
local function root_allocation(c, s, user)
    if c.fullscreen then
        return {float = true, _attach = "output", w = "grow", h = "grow",
            wsrc = "output", hsrc = "output"}
    end
    local bw, word = c.border_width, user and "user" or "legacy"
    return {float = true, _attach = "output", x = c.x - s.geometry.x, y = c.y - s.geometry.y,
        w = c.width + 2 * bw, h = c.height + 2 * bw, wsrc = word, hsrc = word}
end

-- Describe each arranged screen at the frame's clay::declare and hand the
-- node table to the screen; the solve publishes its boxes back onto the
-- table. The suite's tree, or an empty root without one, ends with the
-- clients it did not take, bottom to top, each at its own box.
capi.awesome.connect_signal("clay::declare", function()
    -- A geometry C changed marks the frame dirty at once while the arrange
    -- waits for its delayed call; run it now, or this frame solves the stored
    -- tree and its readback writes the old box over the new one.
    local queued = {}
    for s in pairs(delayed_arrange) do queued[#queued + 1] = s end
    for _, s in ipairs(queued) do
        if delayed_arrange[s] then run_arrange(s) end
    end
    local batch = pending_describe
    pending_describe = {}
    for s in pairs(batch) do
        if s.valid then
            protected_call(function()
                local current = layout.get(s)
                local taken = {}
                local tree = current._clay and expand(current._clay(s), taken)
                    or {name = "WORKAREA", w = "grow", h = "grow", children = {}}
                tree.children = tree.children or {}
                local visible = s.clients
                for i = #visible, 1, -1 do
                    local c = visible[i]
                    if not taken[c] then
                        local user = c.floating or current == layout.suit.floating
                        table.insert(tree.children, describe_client(c, root_allocation(c, s, user)))
                    end
                end
                described[s] = (current._clay or #tree.children > 0) and {tree = tree} or nil
                local stored, reason = s:_clay_layout(tree)
                if stored then
                    refused_warned[s] = nil
                elseif reason and not refused_warned[s] then
                    refused_warned[s] = true
                    gdebug.print_warning("awful.layout: screen " .. s.index ..
                        " layout tree refused (" .. reason .. "), showing nothing")
                end
            end)
        end
    end
end)

capi.screen.connect_signal("clay::solved", function(s, boxes)
    local state = described[s]
    if state then require("wibox.clay")._publish(state, state.tree, boxes) end
end)

-- Every client of a screen is described by its layout pass, so every
-- property the composite or its allocation reads arranges the screen.
local function arrange_prop(obj) layout.arrange(obj.screen) end

for _, signal in ipairs{"property::size_hints_honor", "property::struts",
        "property::minimized", "property::sticky", "property::fullscreen",
        "property::maximized", "property::maximized_horizontal", "property::maximized_vertical",
        "property::border_width", "property::hidden", "property::floating",
        -- What the client composite reads (awful.client.clay).
        "property::border_color", "property::opacity", "property::shadow", "property::shape",
        "property::size_hints", "property::urgent", "property::titlebar_top",
        "property::titlebar_right", "property::titlebar_bottom", "property::titlebar_left",
        "property::_committed_size", "focus", "unfocus"} do
    capi.client.connect_signal(signal, arrange_prop)
end
-- An authored move of a floating client describes it again; a tiled
-- client's geometry that the solve published skips.
capi.client.connect_signal("property::geometry", function(c)
    layout.arrange(c.screen, not client.object.get_floating(c))
end)
capi.client.connect_signal("property::screen", function(c, old_screen)
    if old_screen then
        layout.arrange(old_screen)
    end
    layout.arrange(c.screen)
end)

local function arrange_tag(t)
    layout.arrange(t.screen)
end

capi.tag.connect_signal("property::master_width_factor", arrange_tag)
capi.tag.connect_signal("property::master_count", arrange_tag)
capi.tag.connect_signal("property::column_count", arrange_tag)
capi.tag.connect_signal("property::layout", arrange_tag)
capi.tag.connect_signal("property::windowfact", arrange_tag)
capi.tag.connect_signal("property::selected", arrange_tag)
capi.tag.connect_signal("property::activated", arrange_tag)
capi.tag.connect_signal("property::useless_gap", arrange_tag)
capi.tag.connect_signal("property::master_fill_policy", arrange_tag)
capi.tag.connect_signal("tagged", arrange_tag)
capi.tag.connect_signal("untagged", arrange_tag)

capi.screen.connect_signal("property::workarea", layout.arrange)
capi.screen.connect_signal("padding", layout.arrange)

capi.client.connect_signal("focus", function(c)
    local screen = c.screen
    if screen and layout.get(screen).need_focus_update then
        layout.arrange(screen)
    end
end)
capi.client.connect_signal("raised", function(c) layout.arrange(c.screen) end)
capi.client.connect_signal("lowered", function(c) layout.arrange(c.screen) end)
capi.client.connect_signal("list", function()
                                   for screen in capi.screen do
                                       layout.arrange(screen)
                                   end
                               end)

--- Default handler for `request::geometry` signals for tiled clients with
-- the "mouse.move" context.
-- @tparam client c The client
-- @tparam string context The context
-- @tparam table hints Additional hints
-- @signalhandler awful.layout.move_handler
function layout.move_handler(c, context, hints) --luacheck: no unused args
    -- Quit if it isn't a mouse.move on a tiled layout, that's handled elsewhere
    if c.floating then return end
    if context ~= "mouse.move" then return end

    if capi.mouse.screen ~= c.screen then
        c.screen = capi.mouse.screen
    end

    local l = c.screen.selected_tag and c.screen.selected_tag.layout or nil
    if l == layout.suit.floating then return end

    local c_u_m = capi.mouse.current_client
    if c_u_m and not c_u_m.floating then
        if c_u_m ~= c then
            c:swap(c_u_m)
        end
    end
end

capi.client.connect_signal("request::geometry", layout.move_handler)

-- When a screen is moved, make (floating) clients follow it
capi.screen.connect_signal("property::geometry", function(s, old_geom)
    local geom = s.geometry
    local xshift = geom.x - old_geom.x
    local yshift = geom.y - old_geom.y
    for _, c in ipairs(capi.client.get(s)) do
        local cgeom = c:geometry()
        c:geometry({
            x = cgeom.x + xshift,
            y = cgeom.y + yshift
        })
    end
end)

local init_layouts
init_layouts = function()
    capi.tag.emit_signal("request::default_layouts", "startup")
    capi.tag.disconnect_signal("new", init_layouts)

    -- Fallback.
    if #default_layouts == 0 then
        layout.append_default_layouts({
            layout.suit.floating,
            layout.suit.tile,
            layout.suit.tile.left,
            layout.suit.tile.bottom,
            layout.suit.tile.top,
            layout.suit.fair,
            layout.suit.fair.horizontal,
            layout.suit.spiral,
            layout.suit.spiral.dwindle,
            layout.suit.max,
            layout.suit.max.fullscreen,
            layout.suit.magnifier,
            layout.suit.corner.nw,
            layout.suit.corner.ne,
            layout.suit.corner.sw,
            layout.suit.corner.se,
        })
    end

    init_layouts = nil
end

-- "new" is emitted before "activate", do it should be the very last opportunity
-- generate the list of default layout. With dynamic tag, this can happen later
-- than the first event loop iteration.
capi.tag.connect_signal("new", init_layouts)

-- Intercept the calls to `layouts` to both lazyload then and emit the proper
-- signals.
local mt = {
    __index = function(_, key)
        if key == "layouts" then
            -- Lazy initialization to *at least* attempt to give modules a
            -- chance to load before calling `request::default_layouts`. Note
            -- that the old `rc.lua` called `awful.layout.layouts` in the global
            -- context. If there was some module `require()` later in the code,
            -- they will not get the signal.
            if init_layouts then
                init_layouts()
            end

            return default_layouts
        end
    end,
    __newindex = function(_, key, value)
        if key == "layouts" then
            assert(type(value) == "table", "`awful.layout.layouts` needs a table.")

            -- Do not ask for layouts if they were already provided.
            if init_layouts then
                gdebug.print_warning(
                    "`awful.layout.layouts` was set before `request::default_layouts` could "..
                    "be called. Please use `awful.layout.append_default_layouts` to "..
                    " avoid this problem"
                )

                capi.tag.disconnect_signal("new", init_layouts)
                init_layouts = nil
            elseif #default_layouts > 0 then
                gdebug.print_warning(
                    "`awful.layout.layouts` was set after `request::default_layouts` was "..
                    "used to get the layouts. This is probably an accident. Use "..
                    "`awful.layout.remove_default_layout` to get rid of this warning."
                )
            end

            default_layouts = value
        else
            rawset(layout, key, value)
        end
    end
}

return setmetatable(layout, mt)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
