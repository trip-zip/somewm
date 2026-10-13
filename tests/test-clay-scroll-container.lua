-- luacheck: globals screen awesome
local runner = require("_runner")
local awful = require("awful")
local wibox = require("wibox")

local s = screen[1]
local bar, container, previous, paused_position, idle_dump, resetting
local samples = {}

local function fixture(vertical, size)
    local child = wibox.widget {
        bg = "#204080", forced_width = vertical and 20 or size,
        forced_height = vertical and size or 20,
        widget = wibox.container.background,
    }
    local constructor = vertical and wibox.container.scroll.vertical
        or wibox.container.scroll.horizontal
    container = constructor(child, 20, 100, 40, false, 200,
        wibox.container.scroll.step_functions.linear_increase)
    local layout = vertical and wibox.layout.fixed.vertical()
        or wibox.layout.fixed.horizontal()
    layout:add(container)
    bar = awful.wibar { position = "top", screen = s,
        height = vertical and 240 or 40, widget = layout }
end

local function nodes(dump)
    local d = bar.drawin
    local want = string.format("WIBAR screen %d %dx%d+%d+%d ", s.index,
        d.width, d.height, d.x, d.y)
    local found, clip, backgrounds = false, nil, {}
    for line in dump:gmatch("[^\n]+") do
        if found then
            if not line:match("^    %x+ ") then break end
            if line:find("scroll=", 1, true) then clip = line end
            if line:find("wibox.container.background", 1, true) then
                backgrounds[#backgrounds + 1] = line
            end
        elseif line:find(want, 1, true) then
            found = true
        end
    end
    return clip, backgrounds
end

local function box(line, diagnostic)
    assert(line, diagnostic)
    local x, y, width, height = line:match("box (%-?%d+),(%-?%d+) (%d+)x(%d+)")
    assert(x, diagnostic)
    return tonumber(x), tonumber(y), tonumber(width), tonumber(height)
end

-- The clip line's scrolled value, from the dump alone.
local function position()
    local dump = awesome._clay_tree(s)
    local clip = nodes(dump)
    return clip and tonumber(clip:match("scrolled=(%-?[%d%.]+)")), dump
end

-- The clip line is the viewport, the end of the last background's box is
-- the content's extent and the clip's scrolled value is the position.
local function check_geometry(size, copies, vertical)
    local diagnostic = awesome._clay_tree(s)
    local clip, backgrounds = nodes(diagnostic)
    local x, y, width, height = box(clip, diagnostic)
    local extent = math.min(size, 200)
    local scrolled = tonumber(clip:match("scrolled=(%-?[%d%.]+)"))
    assert(scrolled and scrolled >= 0 and scrolled <= 640, diagnostic)
    assert(#backgrounds == copies, diagnostic)
    assert((vertical and height or width) == extent, diagnostic)
    assert((vertical and width or height) == 20, diagnostic)
    local lx, ly, lw, lh = box(backgrounds[copies], diagnostic)
    local content = (vertical and ly + lh - y or lx + lw - x) + scrolled
    -- The tree dump rounds native float positions to whole pixels.
    assert(math.abs(content - (size * copies + (copies - 1) * 40)) <= 1, diagnostic)
    for i, line in ipairs(backgrounds) do
        local bx, by, bw, bh = box(line, diagnostic)
        assert(bw == (vertical and 20 or size) and bh == (vertical and size or 20), diagnostic)
        local offset = -scrolled + (i - 1) * (size + 40)
        -- The tree dump rounds native float positions to whole pixels.
        assert(math.abs((vertical and by - y or bx - x) - offset) <= 1, diagnostic)
        assert((vertical and bx == x or not vertical and by == y), diagnostic)
    end
    return scrolled, diagnostic
end

local function diagnostics(label, first, last)
    local function counters(dump)
        return string.format("frames=%s mutations=%s commands=%s",
            dump:match("output %S+ scale [^\n]* frames (%d+)") or "?",
            dump:match("mutations (%d+)") or "?", dump:match("commands (%d+)") or "?")
    end
    -- Keep the summary and both dumps within the runner's line-limited output.
    return label .. ": baseline " .. counters(first) .. "; later " .. counters(last)
        .. "\nbaseline dump: " .. first:gsub("\n", "\\n")
        .. "\nlater dump: " .. last:gsub("\n", "\\n")
end

local function at_origin(scrolled)
    return scrolled == 0
end

local first_diagnostic, last_diagnostic
local function settled(count, size, copies, vertical, ready)
    if count == 1 then first_diagnostic, last_diagnostic = nil, nil end
    local ok, r, diagnostic = pcall(check_geometry, size, copies, vertical)
    if not ok or (ready and not ready(r)) then
        last_diagnostic = ok and diagnostic or r
        first_diagnostic = first_diagnostic or last_diagnostic
        assert(count < 25, diagnostics("settlement count " .. count,
            first_diagnostic, last_diagnostic))
        return nil
    end
    last_diagnostic = diagnostic
    return r, diagnostic
end

local function frames(dump)
    return assert(dump:match("output %S+ scale [^\n]* frames (%d+)"), dump)
end

local function sample(count)
    if count == 1 then return nil end
    local r, diagnostic = check_geometry(600, 2, false)
    samples[#samples + 1] = r
    previous = diagnostic
    return count == 6 or nil
end

local steps = {
    function(count)
        if count == 1 then
            fixture(false, 600)
            return nil
        end
        if not settled(count, 600, 2, false) then return nil end
        io.stderr:write("[PASS] horizontal clip is 200 with two 600-wide copies and content 1240\n")
        return true
    end,
    sample,
    sample,
    function()
        local movement = samples[6] - samples[1]
        assert(#samples == 10 and movement > 20 and movement < 300, previous)
        container:pause()
        return true
    end,
    function(count)
        -- A write the timer made before the pause frames first.
        if count == 1 then return nil end
        local r, diagnostic = position()
        paused_position = paused_position or r
        assert(r == paused_position, diagnostic)
        if count < 7 then return nil end
        io.stderr:write("[PASS] ten bounded samples move at the configured speed and pause holds\n")
        container:continue()
        return true
    end,
    function(count)
        if not resetting then
            if not settled(count, 600, 2, false, function(r)
                return r ~= paused_position
            end) then return nil end
            container:pause()
            container:reset_scrolling()
            resetting = count
            return nil
        end
        local reset, reset_diagnostic = position()
        if reset ~= 0 then
            assert(count < resetting + 25, reset_diagnostic)
            return nil
        end
        io.stderr:write("[PASS] continue moves the record and reset_scrolling clears it\n")
        bar:remove()
        fixture(false, 100)
        return true
    end,
    function(count)
        local r, diagnostic = settled(count, 100, 1, false, at_origin)
        if not r then return nil end
        assert(r == 0, diagnostic)
        idle_dump = diagnostic
        return true
    end,
    function(count)
        if count < 6 then return nil end
        local r, diagnostic = settled(count, 100, 1, false)
        if not r then return nil end
        assert(frames(idle_dump) == frames(diagnostic), diagnostics("idle comparison", idle_dump, diagnostic))
        io.stderr:write("[PASS] fitting child stays 100 wide with one copy and an idle band\n")
        bar:remove()
        fixture(true, 600)
        return true
    end,
    function(count)
        local r, diagnostic = settled(count, 600, 2, true, function(scrolled)
            return scrolled > 0
        end)
        if not r then return nil end
        assert(r > 0 and r <= 640, diagnostic)
        previous = r
        return true
    end,
    function(count)
        local r, diagnostic = settled(count, 600, 2, true, function(scrolled)
            return scrolled > previous
        end)
        if not r then return nil end
        assert(r > previous, diagnostic)
        container:pause()
        container:reset_scrolling()
        return true
    end,
    function(count)
        local r, diagnostic = settled(count, 600, 2, true, at_origin)
        if not r then return nil end
        idle_dump = diagnostic
        return true
    end,
    function(count)
        if count < 6 then return nil end
        local r, diagnostic = settled(count, 600, 2, true)
        if not r then return nil end
        assert(r == 0, diagnostic)
        assert(frames(idle_dump) == frames(diagnostic), diagnostics("idle comparison", idle_dump, diagnostic))
        io.stderr:write("[PASS] vertical scrolling changes only y and the final band is idle\n")
        bar:remove()
        return true
    end,
}

runner.run_steps(steps, { wait_per_step = 3 })
