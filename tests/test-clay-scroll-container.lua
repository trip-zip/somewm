-- luacheck: globals screen awesome
local runner = require("_runner")
local awful = require("awful")
local wibox = require("wibox")

local s = screen[1]
local bar, container, previous, paused_position, idle_dump
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

local function snapshot()
    local dump = awesome._clay_tree(s)
    local p = container._private
    local record = p.content and p.content.id
        and { p.drawable:_clay_scroll_get(p.content.id) } or {}
    local diagnostic = dump .. "\nscrolling: " .. tostring(p.scrolling)
        .. "\nscroll record: " .. table.concat(record, ", ")
    return dump, record, diagnostic
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

local function check_geometry(size, copies, vertical)
    local dump, r, diagnostic = snapshot()
    local clip, backgrounds = nodes(dump)
    local x, y, width, height = box(clip, diagnostic)
    local extent = math.min(size, 200)
    local scrolled = tonumber(clip:match("scrolled=(%-?[%d%.]+)"))
    assert(scrolled and scrolled >= 0 and scrolled <= 640, diagnostic)
    assert(#r == 6, diagnostic)
    assert(#backgrounds == copies, diagnostic)
    assert((vertical and height or width) == extent, diagnostic)
    assert((vertical and width or height) == 20, diagnostic)
    assert(r[vertical and 4 or 3] == size * copies + (copies - 1) * 40, diagnostic)
    assert(r[vertical and 6 or 5] == extent, diagnostic)
    assert(r[vertical and 3 or 4] == 20 and r[vertical and 5 or 6] == 20, diagnostic)
    for i, line in ipairs(backgrounds) do
        local bx, by, bw, bh = box(line, diagnostic)
        assert(bw == (vertical and 20 or size) and bh == (vertical and size or 20), diagnostic)
        local offset = -scrolled + (i - 1) * (size + 40)
        -- The tree dump rounds native float positions to whole pixels.
        assert(math.abs((vertical and by - y or bx - x) - offset) <= 1, diagnostic)
        assert((vertical and bx == x or not vertical and by == y), diagnostic)
    end
    return r, diagnostic, scrolled
end

local function diagnostics(label, first, last)
    local function counters(dump)
        return string.format("frames=%s mutations=%s commands=%s",
            dump:match("band desktop [^\n]* frames (%d+)") or "?",
            dump:match("mutations (%d+)") or "?", dump:match("commands (%d+)") or "?")
    end
    -- Keep the summary and both dumps within the runner's line-limited output.
    return label .. ": baseline " .. counters(first) .. "; later " .. counters(last)
        .. "\nbaseline dump: " .. first:gsub("\n", "\\n")
        .. "\nlater dump: " .. last:gsub("\n", "\\n")
end

local function at_origin(record, scrolled)
    return record[1] == 0 and record[2] == 0 and scrolled == 0
end

local first_diagnostic, last_diagnostic
local function settled(count, size, copies, vertical, ready)
    if count == 1 then first_diagnostic, last_diagnostic = nil, nil end
    local ok, r, diagnostic, scrolled = pcall(check_geometry, size, copies, vertical)
    if not ok or (ready and not ready(r, scrolled)) then
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
    return assert(dump:match("band desktop [^\n]* frames (%d+)"), dump)
end

local function sample(count)
    if count == 1 then return nil end
    local r, diagnostic = check_geometry(600, 2, false)
    assert(r[1] >= -640 and r[1] <= 0 and r[2] == 0, diagnostic)
    samples[#samples + 1] = r[1]
    assert(container._private.scrolling, (previous or "") .. "\n" .. diagnostic)
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
        local movement = samples[1] - samples[6]
        assert(#samples == 10 and movement > 20 and movement < 300, previous)
        container:pause()
        local _, r = snapshot()
        paused_position = r[1]
        return true
    end,
    function(count)
        local _, r, diagnostic = snapshot()
        assert(r[1] == paused_position, diagnostic)
        if count < 6 then return nil end
        io.stderr:write("[PASS] ten bounded samples move at the configured speed and pause holds\n")
        container:continue()
        return true
    end,
    function(count)
        if not settled(count, 600, 2, false, function(r)
            return r[1] ~= paused_position
        end) then return nil end
        container:pause()
        container:reset_scrolling()
        local _, reset, reset_diagnostic = snapshot()
        assert(reset[1] == 0 and reset[2] == 0, reset_diagnostic)
        io.stderr:write("[PASS] continue moves the record and reset_scrolling clears it\n")
        bar:remove()
        fixture(false, 100)
        return true
    end,
    function(count)
        local r, diagnostic = settled(count, 100, 1, false, function(record, scrolled)
            return at_origin(record, scrolled) and not container._private.scroll_timer.started
        end)
        if not r then return nil end
        assert(r[1] == 0 and r[2] == 0, diagnostic)
        assert(not container._private.scrolling and not container._private.scroll_timer.started, diagnostic)
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
        local r, diagnostic = settled(count, 600, 2, true, function(record)
            return record[2] < 0
        end)
        if not r then return nil end
        assert(r[1] == 0 and r[2] < 0 and r[2] >= -640, diagnostic)
        previous = r[2]
        return true
    end,
    function(count)
        local r, diagnostic = settled(count, 600, 2, true, function(record)
            return record[2] < previous
        end)
        if not r then return nil end
        assert(r[1] == 0 and r[2] < previous, diagnostic)
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
        assert(r[1] == 0 and r[2] == 0, diagnostic)
        assert(frames(idle_dump) == frames(diagnostic), diagnostics("idle comparison", idle_dump, diagnostic))
        io.stderr:write("[PASS] vertical scrolling changes only y and the final band is idle\n")
        bar:remove()
        return true
    end,
}

runner.run_steps(steps, { wait_per_step = 3 })
