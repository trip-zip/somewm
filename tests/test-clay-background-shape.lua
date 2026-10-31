-- luacheck: globals screen root awesome
-- Run: make test-one TEST=tests/test-clay-background-shape.lua
--
-- Every background shape fills its centre and leaves its corners, read
-- through root.content and, on the headless lanes, through grim (the
-- output's own pixels): a native rounded rectangle is a scene rect with
-- radii, a bordered one a rect with a cutout, and the rest are shape paths.
local runner = require("_runner")
local capture = require("_widget_capture")
local awful = require("awful")
local utils = require("_utils")
local gsurface = require("gears.surface")
local gshape = require("gears.shape")
local wibox = require("wibox")

local s = screen[1]
local BG, RED, BLUE = "#204080", "#ff0000", "#0000ff"
local evidence = os.getenv("SOMEWM_EXAMPLE_EVIDENCE")
local cases = {
    { name = "circle", width = 20, height = 20, shape = gshape.circle },
    { name = "rounded_bar", width = 40, height = 20, shape = gshape.rounded_bar },
    { name = "large-radius closure", width = 40, height = 20,
        shape = function(cr, w, h) gshape.rounded_rect(cr, w, h, 1e6) end },
    { name = "left-rounded rectangle", width = 20, height = 20,
        shape = function(cr, w, h)
            gshape.partially_rounded_rect(cr, w, h, true, false, false, true, 8)
        end, right = RED },
    { name = "powerline", width = 40, height = 20, shape = gshape.powerline,
        top_right_only = true },
    { name = "bordered circle", width = 30, height = 30, shape = gshape.circle,
        border = 2, points = {
            { 15, 15, RED, "corner centre, one radius in" },
            { 0, 0, BG, "corner pixel" } } },
    { name = "native rounded rectangle", width = 20, height = 20,
        shape = gshape.rounded_rect, native = true, points = {
            { 10, 10, RED, "corner centre, one radius in" },
            { 0, 0, BG, "corner pixel" } } },
    -- The cutout: the stroke one radius in along each edge, the fill at the
    -- centre, the wibox behind at the corner.
    { name = "bordered native rounded rectangle", width = 30, height = 30,
        shape = gshape.rounded_rect, native = true, border = 2, points = {
            { 10, 1, BLUE, "stroke one radius in along the top edge" },
            { 1, 10, BLUE, "stroke one radius in along the left edge" },
            { 15, 15, RED, "centre" },
            { 0, 0, BG, "corner pixel" } } },
}
local grim_done, grim_err, ppm

local function nodes(bar)
    local d = bar.drawin
    local want = string.format("  WIBOX screen %d %dx%d+%d+%d ", s.index,
        d.width, d.height, d.x, d.y)
    local found, out = false, {}
    for line in awesome._clay_tree(s):gmatch("[^\n]+") do
        if found then
            if not line:match("^    %x+ ") then break end
            out[#out + 1] = line
        elseif line:sub(1, #want) == want then
            found = true
        end
    end
    return table.concat(out, "\n")
end

local function near(r, g, b, hex)
    return math.abs(r - tonumber(hex:sub(2, 3), 16)) <= 12
        and math.abs(g - tonumber(hex:sub(4, 5), 16)) <= 12
        and math.abs(b - tonumber(hex:sub(6, 7), 16)) <= 12
end

-- One pixel of a binary PPM (P6) as grim -t ppm writes it.
local function ppm_pixel(data, px, py)
    local width, height, header = data:match("^P6%s+(%d+)%s+(%d+)%s+255%s()")
    assert(width, "not a P6 ppm")
    assert(px < tonumber(width) and py < tonumber(height), "pixel outside the capture")
    local at = header + (py * tonumber(width) + px) * 3
    return data:byte(at, at + 2)
end

-- grim reads the output's pixels on the headless lanes; a nested output
-- is not presented by its host, so only root.content is read there.
local function grim()
    local path = os.tmpname()
    grim_done, grim_err, ppm = false, nil, nil
    if not utils.is_headless() then
        grim_done = true
        return
    end
    awful.spawn.easy_async({ "grim", "-t", "ppm", path }, function(_, stderr, _, code)
        if code ~= 0 then
            grim_err = "grim exit " .. tostring(code) .. ": " .. tostring(stderr)
        else
            local f = assert(io.open(path, "rb"))
            ppm = f:read("*a")
            f:close()
            if evidence then
                local out = assert(io.open(evidence .. "/background-shape.ppm", "wb"))
                out:write(ppm)
                out:close()
            end
        end
        os.remove(path)
        grim_done = true
    end)
end

runner.run_steps {
    function(count)
        if count == 1 then
            local x = s.geometry.x + 100
            for _, case in ipairs(cases) do
                case.bar = wibox { x = x, y = s.geometry.y + 100,
                    width = case.width, height = case.height, screen = s,
                    visible = true, bg = BG, widget = wibox.widget {
                        bg = RED, shape = case.shape, border_width = case.border,
                        border_color = BLUE, widget = wibox.container.background,
                    } }
                x = x + case.width + 10
            end
            -- The pointer image is in the output's pixels: park it.
            mouse.coords { x = s.geometry.x + 600, y = s.geometry.y + 400 }
            return nil
        end
        for _, case in ipairs(cases) do
            if #awesome._test_widget_boxes(case.bar.drawin) == 0 then
                assert(count < 20, case.name .. " never converted")
                return nil
            end
        end
        local surface = gsurface(root.content())
        local failures = {}
        local function check(ok, message)
            if not ok then failures[#failures + 1] = message end
        end
        for _, case in ipairs(cases) do
            local before = #failures
            local function pixel(x, y, hex, label)
                local r, g, b = capture.read(surface, case.bar.x + x, case.bar.y + y)
                check(near(r, g, b, hex), string.format("%s %s: expected %s, got (%d,%d,%d)",
                    case.name, label, hex, r, g, b))
            end
            local w, h = case.width, case.height
            pixel(w / 2, h / 2, RED, "centre")
            pixel(w - 2, 1, case.right or BG, "top-right")
            if not case.top_right_only then
                pixel(1, 1, BG, "top-left")
                pixel(1, h - 2, BG, "bottom-left")
                pixel(w - 2, h - 2, case.right or BG, "bottom-right")
            end
            if case.border then pixel(w / 2, 1, BLUE, "top stroke") end
            for _, p in ipairs(case.points or {}) do pixel(p[1], p[2], p[3], p[4]) end
            local dump = nodes(case.bar)
            if case.native then
                local function has_radius(node)
                    if node.radius == 10 and not node.shape then return true end
                    for _, child in ipairs(node.children or {}) do
                        if has_radius(child) then return true end
                    end
                    return false
                end
                check(has_radius(case.bar._drawable._clay_tree),
                    "native rounded rectangle has no compiled radius")
                check(not dump:find(" shape ", 1, true),
                    "native rounded rectangle has a shape command: " .. dump)
                if case.border then
                    check(awesome._clay_tree(s):find(" BORDER%s+z=%-%s+box %d+,%d+ 30x30"),
                        "bordered native rounded rectangle has no BORDER command")
                end
            else
                check(dump:find(" shape ", 1, true), case.name .. " has no shape command")
            end
            if #failures == before then
                io.stderr:write("[PASS] " .. case.name .. " fill, corners and paint command\n")
            else
                local messages = {}
                for i = before + 1, #failures do messages[#messages + 1] = failures[i] end
                for i = #failures, before + 1, -1 do failures[i] = nil end
                failures[#failures + 1] = table.concat(messages, "; ")
            end
        end
        local log = assert(io.open(assert(os.getenv("SOMEWM_TEST_LOG")), "r"))
        local contents = log:read("*a")
        log:close()
        check(not contents:find("is not a rounded rectangle", 1, true),
            contents:match("[^\n]*is not a rounded rectangle[^\n]*")
                or "compositor log contains the rounded-rectangle warning")
        assert(#failures == 0, table.concat(failures, "\n"))
        io.stderr:write("[PASS] no rounded-rectangle warnings\n")
        grim()
        return true
    end,
    -- The corner-centre points again, through grim and root.content side
    -- by side; the values read go beside the capture when evidence is saved.
    function(count)
        if not grim_done then assert(count < 40, "grim did not finish"); return nil end
        assert(not grim_err, grim_err)
        local surface = gsurface(root.content())
        local lines = {}
        for _, case in ipairs(cases) do
            for _, p in ipairs(case.points or {}) do
                local x, y = case.bar.x + p[1], case.bar.y + p[2]
                local r, g, b = capture.read(surface, x, y)
                local content = string.format("#%02x%02x%02x", r, g, b)
                local captured = "not captured"
                if ppm then
                    local gr, gg, gb = ppm_pixel(ppm, x, y)
                    captured = string.format("#%02x%02x%02x", gr, gg, gb)
                    assert(near(gr, gg, gb, p[3]), string.format("%s %s: grim at %d,%d is %s, want %s",
                        case.name, p[4], x, y, captured, p[3]))
                end
                assert(near(r, g, b, p[3]), string.format("%s %s: content at %d,%d is %s, want %s",
                    case.name, p[4], x, y, content, p[3]))
                lines[#lines + 1] = string.format("%s %s at %d,%d: content %s grim %s want %s",
                    case.name, p[4], x, y, content, captured, p[3])
                io.stderr:write("[PASS] " .. lines[#lines] .. "\n")
            end
        end
        if evidence then
            local out = assert(io.open(evidence .. "/background-shape.pixels", "w"))
            out:write(table.concat(lines, "\n"), "\n")
            out:close()
        end
        return true
    end,
    function()
        for _, case in ipairs(cases) do case.bar.visible = false end
        return true
    end,
}
