-- The client composite as nodes (spec R100): the frame with its border,
-- the titlebar hosts, the slot and the surface leaf. awful.layout expands a
-- suite's {client = c} leaves through describe before handing the tree to
-- the screen; declare.c reads no client field to compose it.
local gdebug = require("gears.debug")
local wclay = require("wibox.clay")

local animation = require("somewm.animation")
local capi = {client = client}
local GLib = require("lgi").GLib
local clay = {}
local previous = setmetatable({}, {__mode = "k"})

local allocation_keys = {"w", "h", "wsrc", "hsrc", "float", "x", "y", "parent", "own", "_attach"}
local bounds = {wmin = "min_width", wmax = "max_width", hmin = "min_height", hmax = "max_height"}

local function bar(c, name, side, horizontal)
    local drawable, size = c["titlebar_" .. side](c)
    if size == 0 then return nil end
    if horizontal then
        return {name = name, host = drawable, w = "grow", h = size, hsrc = "theme"}
    end
    return {name = name, host = drawable, w = size, h = "grow", wsrc = "theme"}
end

-- A max hint at or past the reader's range leaves its axis unbounded, as
-- the protocol's 0 does; the client warns once per field.
local unbounded_warned = setmetatable({}, {__mode = "k"})
local function surface(c, fullscreen)
    local node = {name = "SURFACE", surface = c, float = true, w = "grow", h = "grow",
        opacity = c.opacity}
    if c.size_hints_honor and not fullscreen then
        local hints = c.size_hints
        for key, field in pairs(bounds) do
            local value = hints[field] or 0
            if value >= 1e6 and (key == "wmax" or key == "hmax") then
                local warned = unbounded_warned[c] or {}
                unbounded_warned[c] = warned
                if not warned[field] then
                    warned[field] = true
                    gdebug.print_warning("awful.client.clay: client " .. tostring(c.class) ..
                        " " .. field .. " " .. string.format("%d", value) ..
                        " is past the solver's range, the axis is unbounded")
                end
            elseif value > 0 then
                node[key] = value
                node.wsrc, node.hsrc = "protocol", "protocol"
            end
        end
    end
    return node
end

-- The radius c.shape stands for: a number as given; a function through
-- wibox.clay's rounded rectangle detection (gears.shape.rounded_rect or a
-- closure drawing its path). Any other function warns once per client and
-- function, naming the client, and the client is described square; c.shape
-- keeps what was set, as a wibox keeps its function.
local shape_warned = setmetatable({}, {__mode = "k"})
local function shape_radius(c)
    local shape = c.shape
    if shape == nil then return 0 end
    if type(shape) == "number" then return shape end
    local r = wclay.shape_radius(shape)
    if r then return r end
    if shape_warned[c] ~= shape then
        shape_warned[c] = shape
        gdebug.print_warning("client: shape is not a rounded rectangle, the client stays square: "
            .. tostring(c.class or c.name))
    end
    return 0
end

-- The corners of the shape, less the border as a wibox's content takes
-- them: a titlebar on an edge takes that edge's corners, the surface the
-- rest. Nothing is authored when the client is square. A border stays
-- square here and takes a click in the corner; without one the surface's
-- own cut corner lets the click through.
local function assign_corners(c, bw, top, right, bottom, left, pixels)
    local r = math.max(shape_radius(c) - bw, 0)
    if r <= 0 then return end
    local radii = {r, r, r, r}  -- top-left, top-right, bottom-right, bottom-left
    if top then top.radii = {r, r, 0, 0}; radii[1], radii[2] = 0, 0 end
    if bottom then bottom.radii = {0, 0, r, r}; radii[3], radii[4] = 0, 0 end
    if left then left.radii = {radii[1], 0, 0, radii[4]}; radii[1], radii[4] = 0, 0 end
    if right then right.radii = {0, radii[2], radii[3], 0}; radii[2], radii[3] = 0, 0 end
    pixels.radii = radii
end

-- The bars around a slot, top to bottom: the top bar, a row of the left
-- bar, the slot and the right bar, the bottom bar.
local function around(top, right, bottom, left, slot, row_name)
    local body = slot
    if left or right then
        local row = {}
        row[#row + 1] = left
        row[#row + 1] = slot
        row[#row + 1] = right
        body = {name = row_name, w = "grow", h = "grow", children = row}
    end
    local children = {}
    children[#children + 1] = top
    children[#children + 1] = body
    children[#children + 1] = bottom
    return children
end

-- An empty node holding a bar's place in the probe.
local function spacer(name, node)
    if not node then return nil end
    if node.w == "grow" then return {name = name, w = "grow", h = node.h, hsrc = "theme"} end
    return {name = name, w = node.w, h = "grow", wsrc = "theme"}
end

--- The composite for c at a layout's allocation: the frame carries the
-- allocation's sizing, words and float; a padded float is a cell holding
-- the frame at its whole inset. When the client drew a size other than the
-- one configured (c._committed_size), the frame holds the chrome, which
-- wraps the surface at the drawn size from the frame's top-left, and the
-- probe, the frame's box less the border and bars, whose size is what the
-- client is configured. The chrome clips: a clip element takes none of its
-- children's minimum (third_party/clay.h:1893-1925), so a drawn size past
-- the allocation is cut at it and never grows the frame.
function clay.describe(c, allocation)
    local frame = {name = "CLIENT", client = c, dir = "y"}
    for _, key in ipairs(allocation_keys) do frame[key] = allocation[key] end
    local fullscreen = c.fullscreen
    local bw = fullscreen and 0 or c.border_width
    local top, right, bottom, left
    if not fullscreen then
        top = bar(c, "TITLEBAR", "top", true)
        right = bar(c, "TITLEBAR_RIGHT", "right", false)
        bottom = bar(c, "TITLEBAR_BOTTOM", "bottom", true)
        left = bar(c, "TITLEBAR_LEFT", "left", false)
    end
    local committed = c._committed_size
    local pixels = surface(c, fullscreen)
    local slot = {name = "SLOT", w = "grow", h = "grow", children = {pixels}}
    if committed then
        pixels.w, pixels.h, pixels.wsrc, pixels.hsrc = committed.width, committed.height, "protocol", "protocol"
        pixels.wmin, pixels.wmax, pixels.hmin, pixels.hmax = nil, nil, nil, nil
        slot.w, slot.h, slot.wsrc, slot.hsrc = committed.width, committed.height, "protocol", "protocol"
    end
    if not fullscreen then
        assign_corners(c, bw, top, right, bottom, left, pixels)
    end
    local box = frame
    if committed then
        box = {name = "CHROME", client = c, dir = "y", w = "fit", h = "fit", scroll = "both"}
        local probe = surface(c, fullscreen)
        probe.name, probe.probe, probe.opacity = "CONFIGURE", true, nil
        frame.children = {box, {name = "PROBE", float = true, w = "grow", h = "grow", dir = "y",
            pad = {bw, bw, bw, bw}, children = around(spacer("PROBE_TOP", top), spacer("PROBE_RIGHT", right),
                spacer("PROBE_BOTTOM", bottom), spacer("PROBE_LEFT", left),
                {name = "PROBE_SLOT", w = "grow", h = "grow", children = {probe}}, "PROBE_BODY")}}
    end
    box.children = around(top, right, bottom, left, slot, "CLIENT_BODY")
    box.pad = {bw, bw, bw, bw}
    if bw > 0 then
        box.border, box.bw = {c:_border_rgba()}, {bw, bw, bw, bw}
    end
    local state = previous[c]
    local focused = capi.client.focus == c
    local now = GLib.get_monotonic_time()
    local trigger, started = "layout", nil
    local focus_started = state and state.focus_started
    if not state then
        trigger, started = "appear", now
    elseif state.hidden then
        trigger, started = "tag", now
    else
        if state.maximized ~= c.maximized or state.fullscreen ~= fullscreen then
            trigger, started = "maximize", now
        elseif state.floating ~= c.floating then
            trigger, started = "floating", now
        elseif state.started and (now - state.started) / 1e6 < animation.duration(c, state.trigger) then
            -- clay.h:4727 reads the duration from the current declaration each frame,
            -- so a redeclare while the transition runs must not change it.
            trigger, started = state.trigger, state.started
        end
        if state.focused ~= focused then focus_started = now end
    end
    local triggers = trigger
    if focus_started and (now - focus_started) / 1e6 < animation.duration(c, "focus") then
        triggers = {trigger, "focus"}
    else
        focus_started = nil
    end
    frame.transition = animation.word(c, triggers)
    if (trigger == "appear" or trigger == "tag") and not (frame.transition and frame.transition.enter) then
        trigger, started = "layout", nil
    end
    if frame.transition and (frame.transition.enter == "grow" or frame.transition.enter == "collapse"
        or frame.transition.exit == "grow" or frame.transition.exit == "collapse"
        or frame.transition.tag_exit == "grow" or frame.transition.tag_exit == "collapse") then
        frame.scroll = "both"
    end
    if box ~= frame and frame.transition and type(frame.transition.properties) == "table" then
        box.transition = {properties = "border_color", duration = frame.transition.duration}
    end
    previous[c] = {maximized = c.maximized, fullscreen = fullscreen, floating = c.floating,
        trigger = trigger, started = started, focused = focused, focus_started = focus_started}
    local pad = allocation.pad
    if not (allocation.float and pad and (pad[1] ~= 0 or pad[2] ~= 0 or pad[3] ~= 0 or pad[4] ~= 0)) then
        return frame
    end
    local cell = {name = "CELL", client = c, pad = pad, children = {frame}}
    for _, key in ipairs(allocation_keys) do cell[key], frame[key] = allocation[key], nil end
    frame.w, frame.h, frame.wsrc, frame.hsrc = {percent = 1}, {percent = 1}, "theme", "theme"
    return cell
end

if capi.client.connect_signal then
    capi.client.connect_signal("request::manage", function(c) previous[c] = nil end)
end
if tag and tag.connect_signal then
    tag.connect_signal("property::selected", function()
        for c, state in pairs(previous) do
            if c.valid and not c:isvisible() then state.hidden = true end
        end
    end)
end

return clay
