--[[
  Focus Debug Script for somewm-client

  Usage: somewm-client "$(cat plans/debug-focus.lua)"

  Dumps comprehensive focus state for debugging the ALFA problem.
]]

local output = {}

local function add(fmt, ...)
    table.insert(output, string.format(fmt, ...))
end

add("=== somewm Focus Debug ===")
add("Time: %s", os.date("%Y-%m-%d %H:%M:%S"))
add("")

-- Focused client
local fc = client.focus
if fc then
    add("FOCUSED CLIENT:")
    add("  name:      %s", tostring(fc.name))
    add("  class:     %s", tostring(fc.class))
    add("  instance:  %s", tostring(fc.instance))
    add("  type:      %s", tostring(fc.type))
    add("  focusable: %s", tostring(fc.focusable))
    add("  floating:  %s", tostring(fc.floating))
    add("  fullscr:   %s", tostring(fc.fullscreen))
    add("  hidden:    %s", tostring(fc.hidden))
    add("  minimized: %s", tostring(fc.minimized))
    add("  pid:       %s", tostring(fc.pid))
    add("  geometry:  %dx%d+%d+%d", fc.width or 0, fc.height or 0, fc.x or 0, fc.y or 0)
    if fc.screen then
        add("  screen:    %s", tostring(fc.screen.index))
    end
    local tags = fc:tags()
    local tnames = {}
    for _, t in ipairs(tags) do
        table.insert(tnames, t.name)
    end
    add("  tags:      [%s]", table.concat(tnames, ", "))
else
    add("FOCUSED CLIENT: none")
end

add("")

-- All clients
add("ALL CLIENTS (%d):", #client.get())
for i, c in ipairs(client.get()) do
    local is_focused = (c == client.focus) and " *FOCUSED*" or ""
    add("  [%d] %s (%s) focusable=%s hidden=%s%s",
        i,
        tostring(c.name),
        tostring(c.class),
        tostring(c.focusable),
        tostring(c.hidden),
        is_focused)
end

add("")

-- Screens
add("SCREENS (%d):", screen.count())
for s in screen do
    local geo = s.geometry
    add("  Screen %d: %dx%d+%d+%d", s.index, geo.width, geo.height, geo.x, geo.y)
    local stags = s.tags
    local selected = {}
    for _, t in ipairs(stags) do
        if t.selected then
            table.insert(selected, t.name)
        end
    end
    add("    Selected tags: [%s]", table.concat(selected, ", "))
end

add("")

-- Focus history
local awful = require("awful")
add("FOCUS HISTORY:")
local history = awful.client.focus.history.list
if history then
    for i, c in ipairs(history) do
        if i > 5 then
            add("  ... (%d more)", #history - 5)
            break
        end
        add("  [%d] %s (%s)", i, tostring(c.name), tostring(c.class))
    end
    if #history == 0 then
        add("  (empty)")
    end
else
    add("  (unavailable)")
end

add("")

-- Compositor info
add("COMPOSITOR:")
add("  version:  %s", tostring(awesome.version))
add("  hostname: %s", tostring(awesome.hostname))

return table.concat(output, "\n")
