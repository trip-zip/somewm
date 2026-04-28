---------------------------------------------------------------------------
--- Mouse snapping related functions
--
-- @author Julien Danjou &lt;julien@danjou.info&gt;
-- @copyright 2008 Julien Danjou
-- @submodule mouse
---------------------------------------------------------------------------

local aclient   = require("awful.client")
local resize    = require("awful.mouse.resize")
local aplace    = require("awful.placement")
local wibox     = require("wibox")
local beautiful = require("beautiful")
local color     = require("gears.color")
local shape     = require("gears.shape")
local cairo     = require("lgi").cairo
local GLib      = require("lgi").GLib
local alayout   = require("awful.layout")

local capi = {
    root = root,
    mouse = mouse,
    screen = screen,
    client = client,
    mousegrabber = mousegrabber,
}

local module = {
    default_distance  = 8,
    aerosnap_distance = 16,
    -- Minimum time the cursor must dwell inside an aerosnap edge zone
    -- before the placeholder is shown.  Flying past an edge during a
    -- cross-monitor drag (typical: <50 ms in the edge band) never
    -- lights up the placeholder and never damages the second output.
    -- Set to 0 to restore the legacy behaviour (show on first tick).
    snap_dwell_ms     = 150,
}

local placeholder_w = nil

local function show_placeholder(geo)
    if not geo then
        if placeholder_w then
            placeholder_w.visible = false
        end
        return
    end

    placeholder_w = placeholder_w or wibox {
        ontop = true,
        bg    = color(beautiful.snap_bg or beautiful.bg_urgent or "#ff0000"),
    }

    placeholder_w:geometry(geo)

    local img = cairo.ImageSurface(cairo.Format.ARGB32, geo.width, geo.height)
    local cr = cairo.Context(img)
    cr:set_antialias(cairo.Antialias.BEST)

    cr:set_operator(cairo.Operator.CLEAR)
    cr:set_source_rgba(0,0,0,1)
    cr:paint()
    cr:set_operator(cairo.Operator.SOURCE)
    cr:set_source_rgba(1,1,1,1)

    local line_width = beautiful.snap_border_width or 5
    cr:set_line_width(beautiful.xresources.apply_dpi(line_width))

    local f = beautiful.snap_shape or function()
        cr:translate(line_width,line_width)
        shape.rounded_rect(cr,geo.width-2*line_width,geo.height-2*line_width, 10)
    end

    f(cr, geo.width, geo.height)

    cr:stroke()

    placeholder_w.shape_bounding = img._native
    placeholder_w._shape_bounding_surface = img  -- Keep reference to prevent GC

    placeholder_w.visible = true
end

local function build_placement(snap, axis)
    return aplace.scale
        + aplace[snap]
        + (
            axis and aplace["maximize_"..axis] or nil
          )
end

local function detect_screen_edges(c, snap)
    local coords = capi.mouse.coords()

    local sg = c.screen.geometry

    local v, h = nil

    if math.abs(coords.x) <= snap + sg.x and coords.x >= sg.x then
        h = "left"
    elseif math.abs((sg.x + sg.width) - coords.x) <= snap then
        h = "right"
    end

    if math.abs(coords.y) <= snap + sg.y and coords.y >= sg.y then
        v = "top"
    elseif math.abs((sg.y + sg.height) - coords.y) <= snap then
        v = "bottom"
    end

    return v, h
end

local current_snap, current_axis = nil
-- Monotonic timestamp (µs) at which the cursor first entered the
-- current snap zone.  Used to enforce `module.snap_dwell_ms`: the
-- placeholder is only shown once the cursor has been in the same
-- edge zone for at least that long.  0 means "not currently in any
-- snap zone".
local current_snap_entered_us = 0
-- Whether `show_placeholder` has been called with a non-nil geometry
-- for the current snap zone.  Used to gate `apply_areasnap`: a
-- release without prior visual confirmation is treated as a no-op.
local current_snap_visible = false

local function reset_snap_state()
    current_snap = nil
    current_axis = nil
    current_snap_entered_us = 0
    current_snap_visible = false
end

local function show_snap_for(c)
    show_placeholder(build_placement(current_snap, current_axis)(c, {
        to_percent     = 0.5,
        honor_workarea = true,
        honor_padding  = true,
        pretend        = true,
        margins        = beautiful.snapper_gap
    }))
    current_snap_visible = true
end

local function detect_areasnap(c, distance)
    if (not c.floating) and alayout.get(c.screen) ~= alayout.suit.floating then
        return
    end

    local old_snap = current_snap
    local v, h = detect_screen_edges(c, distance)

    if v and h then
        current_snap = v.."_"..h
    else
        current_snap = v or h or nil
    end

    local dwell_ms = module.snap_dwell_ms or 0

    -- Snap zone changed: refresh axis + dwell timestamp, hide any
    -- previously visible placeholder.  In dwell mode we re-show only
    -- after the dwell threshold below, never on the first tick of
    -- entering a new zone — that's what eliminates the flicker when
    -- the cursor briefly grazes an edge while flying between monitors.
    -- With dwell disabled (snap_dwell_ms <= 0) we restore legacy
    -- behaviour and show immediately on entry.
    if old_snap ~= current_snap then
        current_axis = ((v and not h) and "horizontally")
            or ((h and not v) and "vertically")
            or nil
        current_snap_entered_us = current_snap and GLib.get_monotonic_time() or 0
        current_snap_visible = false
        show_placeholder(nil)
        if current_snap and dwell_ms <= 0 then
            show_snap_for(c)
        end
        return
    end

    -- Same zone as last tick: defer placeholder until the cursor has
    -- dwelled long enough.  Fast cross-monitor flights graze the
    -- edge band for <50 ms and never satisfy the dwell, so the
    -- destination output is never damaged with a placeholder.
    if not current_snap or current_snap_visible or current_snap_entered_us == 0 then
        return
    end

    if dwell_ms > 0 then
        local elapsed_us = GLib.get_monotonic_time() - current_snap_entered_us
        if elapsed_us < dwell_ms * 1000 then return end
    end

    show_snap_for(c)
end

local function apply_areasnap(c, args)
    if not current_snap then return end

    -- If the placeholder was never shown for this zone, the user got
    -- no visual confirmation that a snap was about to happen.  Treat
    -- release as a no-op rather than surprising them with a layout
    -- change.
    if not current_snap_visible then
        reset_snap_state()
        return
    end

    -- Remove the move offset
    args.offset = {}

    if placeholder_w then placeholder_w.visible = false end

    -- Snapshot the placement choice before clearing state so the
    -- next drag — even one that immediately re-enters the same edge
    -- zone — starts with a clean slate.
    local snap, axis = current_snap, current_axis
    reset_snap_state()

    return build_placement(snap, axis)(c, {
        to_percent     = 0.5,
        honor_workarea = true,
        honor_padding  = true,
        margins        = beautiful.snapper_gap
    })
end

local function snap_outside(g, sg, snap)
    if g.x < snap + sg.x + sg.width and g.x > sg.x + sg.width then
        g.x = sg.x + sg.width
    elseif g.x + g.width < sg.x and g.x + g.width > sg.x - snap then
        g.x = sg.x - g.width
    end
    if g.y < snap + sg.y + sg.height and g.y > sg.y + sg.height then
        g.y = sg.y + sg.height
    elseif g.y + g.height < sg.y and g.y + g.height > sg.y - snap then
        g.y = sg.y - g.height
    end
    return g
end

local function snap_inside(g, sg, snap)
    local edgev = 'none'
    local edgeh = 'none'
    if math.abs(g.x) < snap + sg.x and g.x > sg.x then
        edgev = 'left'
        g.x = sg.x
    elseif math.abs((sg.x + sg.width) - (g.x + g.width)) < snap then
        edgev = 'right'
        g.x = sg.x + sg.width - g.width
    end
    if math.abs(g.y) < snap + sg.y and g.y > sg.y then
        edgeh = 'top'
        g.y = sg.y
    elseif math.abs((sg.y + sg.height) - (g.y + g.height)) < snap then
        edgeh = 'bottom'
        g.y = sg.y + sg.height - g.height
    end

    -- What is the dominant dimension?
    if g.width > g.height then
        return g, edgeh
    else
        return g, edgev
    end
end

--- Snap a client to the closest client or screen edge.
--
-- @function awful.mouse.snap
-- @tparam[opt=client.focus] client c The client to snap.
-- @tparam integer snap The pixel to snap clients.
-- @tparam integer x The client x coordinate.
-- @tparam integer y The client y coordinate.
-- @tparam boolean fixed_x True if the client isn't allowed to move in the x direction.
-- @tparam boolean fixed_y True if the client isn't allowed to move in the y direction.
-- @treturn table The new geometry.
-- @usebeautiful beautiful.snap_bg
-- @usebeautiful beautiful.snap_border_width
-- @usebeautiful beautiful.snap_shape
-- @usebeautiful beautiful.snapper_gap
function module.snap(c, snap, x, y, fixed_x, fixed_y)
    snap = snap or module.default_distance
    c = c or capi.client.focus
    local cur_geom = c:geometry()
    local geom = c:geometry()
    local snapper_gap = beautiful.snapper_gap or 0
    local edge
    geom.x = (x or geom.x) - snapper_gap
    geom.y = (y or geom.y) - snapper_gap
    geom.width = geom.width + (2 * c.border_width) + (2 * snapper_gap)
    geom.height = geom.height + (2 * c.border_width) + (2 * snapper_gap)

    geom, edge = snap_inside(geom, c.screen.geometry, snap)
    geom = snap_inside(geom, c.screen.tiling_area, snap)

    -- Allow certain windows to snap to the edge of the workarea.
    -- Only allow docking to workarea for consistency/to avoid problems.
    if c.dockable then
        local struts = c:struts()
        struts['left'] = 0
        struts['right'] = 0
        struts['top'] = 0
        struts['bottom'] = 0
        if edge ~= "none" and c.floating then
            if edge == "left" or edge == "right" then
                struts[edge] = cur_geom.width
            elseif edge == "top" or edge == "bottom" then
                struts[edge] = cur_geom.height
            end
        end
        c:struts(struts)
    end

    for _, snapper in ipairs(aclient.visible(c.screen)) do
        if snapper ~= c then
            local snapper_geom = snapper:geometry()
            snapper_geom.x = snapper_geom.x - snapper_gap
            snapper_geom.y = snapper_geom.y - snapper_gap
            snapper_geom.width = snapper_geom.width + (2 * snapper.border_width) + (2 * snapper_gap)
            snapper_geom.height = snapper_geom.height + (2 * snapper.border_width) + (2 * snapper_gap)
            geom = snap_outside(geom, snapper_geom, snap)
        end
    end

    geom.x = geom.x + snapper_gap
    geom.y = geom.y + snapper_gap
    geom.width = geom.width - (2 * c.border_width) - (2 * snapper_gap)
    geom.height = geom.height - (2 * c.border_width) - (2 * snapper_gap)

    -- It's easiest to undo changes afterwards if they're not allowed
    if fixed_x then geom.x = cur_geom.x end
    if fixed_y then geom.y = cur_geom.y end

    return geom
end

-- Enable edge snapping
resize.add_move_callback(function(c, geo, args)
    -- Screen edge snapping (areosnap)
    if (module.edge_enabled ~= false)
      and args and (args.snap == nil or args.snap) then
        detect_areasnap(c, module.aerosnap_distance)
    end

    -- Snapping between clients
    if (module.client_enabled ~= false)
      and args and (args.snap == nil or args.snap) then
        return module.snap(c, args.snap, geo.x, geo.y)
    end
end, "mouse.move")

-- Apply the aerosnap
resize.add_leave_callback(function(c, _, args)
    if module.edge_enabled == false then return end
    return apply_areasnap(c, args)
end, "mouse.move")

return setmetatable(module, {__call = function(_, ...) return module.snap(...) end})

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
