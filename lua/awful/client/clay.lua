-- The client composite as nodes (spec R100): the frame with its border,
-- the titlebar hosts, the slot and the surface leaf. awful.layout expands a
-- suite's {client = c} leaves through describe before handing the tree to
-- the screen; declare.c reads no client field to compose it.
local capi = {mousegrabber = mousegrabber}
local gdebug = require("gears.debug")

local clay = {}

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

--- The composite for c at a layout's allocation: the frame carries the
-- allocation's sizing, words and float; a padded float is a cell holding
-- the frame at its whole inset.
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
    local body = {name = "SLOT", w = "grow", h = "grow", children = {surface(c, fullscreen)}}
    if left or right then
        local row = {}
        row[#row + 1] = left
        row[#row + 1] = body
        row[#row + 1] = right
        body = {name = "CLIENT_BODY", w = "grow", h = "grow", children = row}
    end
    local children = {}
    children[#children + 1] = top
    children[#children + 1] = body
    children[#children + 1] = bottom
    frame.children = children
    frame.pad = {bw, bw, bw, bw}
    if bw > 0 then
        frame.border, frame.bw = {c:_border_rgba()}, {bw, bw, bw, bw}
    end
    -- Loading somewm.layout_animation turns the transition on; without it
    -- a frame snaps.
    local animation = package.loaded["somewm.layout_animation"]
    frame.transition = {properties = "box", duration = animation and animation.enabled
        and not capi.mousegrabber.isrunning() and animation.duration or 0}
    local pad = allocation.pad
    if not (allocation.float and pad and (pad[1] ~= 0 or pad[2] ~= 0 or pad[3] ~= 0 or pad[4] ~= 0)) then
        return frame
    end
    local cell = {name = "CELL", client = c, pad = pad, children = {frame}}
    for _, key in ipairs(allocation_keys) do cell[key], frame[key] = allocation[key], nil end
    frame.w, frame.h, frame.wsrc, frame.hsrc = {percent = 1}, {percent = 1}, "theme", "theme"
    return cell
end

return clay
