-- luacheck: globals screen root awesome
-- Run: make test-one TEST=tests/test-clay-background-shape.lua
local runner = require("_runner")
local capture = require("_widget_capture")
local gsurface = require("gears.surface")
local gshape = require("gears.shape")
local wibox = require("wibox")

local s = screen[1]
local BG, RED, BLUE = "#204080", "#ff0000", "#0000ff"
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
        border = 2 },
    { name = "native rounded rectangle", width = 20, height = 20,
        shape = gshape.rounded_rect, native = true },
}

local function nodes(bar)
    local d = bar.drawin
    local want = string.format("  drawin screen %d %dx%d+%d+%d ", s.index,
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
                check(math.abs(r - tonumber(hex:sub(2, 3), 16)) <= 12
                    and math.abs(g - tonumber(hex:sub(4, 5), 16)) <= 12
                    and math.abs(b - tonumber(hex:sub(6, 7), 16)) <= 12,
                    string.format("%s %s: expected %s, got (%d,%d,%d)",
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
        return true
    end,
    function()
        for _, case in ipairs(cases) do case.bar.visible = false end
        return true
    end,
}
