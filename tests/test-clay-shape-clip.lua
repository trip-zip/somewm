-- luacheck: globals screen root awesome
local runner = require("_runner")
local capture = require("_widget_capture")
local gsurface = require("gears.surface")
local gshape = require("gears.shape")
local awful = require("awful")
local wibox = require("wibox")
local cairo = require("lgi").cairo

local s = screen[1]
local BG, RED, BLUE = "#204080", "#ff0000", "#0000ff"
local failures, clicks = {}, 0
local function check(ok, message)
    if not ok then
        failures[#failures + 1] = message
        io.stderr:write("[FAIL] " .. message .. "\n")
    end
end
local function background(child, shape, color)
    return wibox.widget { child, bg = color, shape = shape,
        widget = wibox.container.background }
end
local child = background(nil, nil, BLUE)
child:buttons { awful.button({}, 1, function() clicks = clicks + 1 end) }
local rounded_clicks = 0
local rounded_child = background(nil, nil, BLUE)
rounded_child:buttons { awful.button({}, 1, function() rounded_clicks = rounded_clicks + 1 end) }
local red = cairo.ImageSurface.create(cairo.Format.ARGB32, 40, 40)
local cr = cairo.Context(red)
cr:set_source_rgb(1, 0, 0)
cr:paint()
local cases = {
    { name = "circle child", width = 40, height = 40,
        widget = background(child, gshape.circle, RED), center = BLUE },
    { name = "nested rounded child", width = 40, height = 40,
        widget = background(background(nil, function(ctx, w, h)
            gshape.rounded_rect(ctx, w, h, 4)
        end, BLUE), gshape.circle, RED), center = BLUE, nested = true },
    { name = "imagebox clip_shape", width = 40, height = 40,
        widget = wibox.widget { image = red, clip_shape = gshape.circle,
            widget = wibox.widget.imagebox }, center = RED },
    { name = "progressbar clip", width = 40, height = 12,
        widget = wibox.widget { shape = gshape.rounded_bar, clip = true,
            value = 1, color = BLUE, background_color = RED,
            widget = wibox.widget.progressbar }, center = BLUE },
    { name = "slider active bar", width = 60, height = 12,
        widget = wibox.widget { bar_shape = gshape.rounded_bar,
            value = 100, maximum = 100, bar_color = RED, bar_active_color = BLUE,
            handle_width = 0, handle_color = "#00000000",
            widget = wibox.widget.slider }, center = BLUE },
    { name = "rounded child", width = 40, height = 40,
        widget = background(rounded_child, function(ctx, w, h)
            gshape.rounded_rect(ctx, w, h, 12)
        end, RED), center = BLUE },
}
local function click(x, y, index)
    local g = s.geometry
    awful.spawn { "./build-test/test-virtual-pointer-client", "click",
        tostring(cases[index or 1].bar.x + x), tostring(cases[index or 1].bar.y + y),
        tostring(g.width), tostring(g.height) }
end
runner.run_steps {
    function(count)
        if count == 1 then
            local x = s.geometry.x + 100
            for _, case in ipairs(cases) do
                case.bar = wibox { x = x, y = s.geometry.y + 100,
                    width = case.width, height = case.height, screen = s,
                    visible = true, bg = BG, widget = case.widget }
                x = x + case.width + 10
            end
            return
        end
        for _, case in ipairs(cases) do
            if #awesome._test_widget_boxes(case.bar.drawin) == 0 then
                assert(count < 20, case.name .. " never converted")
                return
            end
        end
        local surface = gsurface(root.content())
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
            pixel(w / 2, h / 2, case.center, "centre")
            local inset = h == 12 and 0 or 1
            pixel(inset, inset, BG, "top-left")
            pixel(w - 1 - inset, inset, BG, "top-right")
            pixel(inset, h - 1 - inset, BG, "bottom-left")
            pixel(w - 1 - inset, h - 1 - inset, BG, "bottom-right")
            if case.nested then pixel(4, 2, BG, "inside inner arc, outside circle") end
            if #failures == before then io.stderr:write("[PASS] " .. case.name .. " pixels\n") end
        end
        local log = assert(io.open(assert(os.getenv("SOMEWM_TEST_LOG")), "r"))
        local contents = log:read("*a")
        log:close()
        local before = #failures
        for _, warning in ipairs { "clip_shape is not applied", "is not cut to the shape",
            "does not cut the active bar" } do
            check(not contents:find(warning, 1, true), "warning: " .. warning)
        end
        if #failures == before then io.stderr:write("[PASS] no shape clip warnings\n") end
        click(1, 1)
        return true
    end,
    function(count)
        if count < 5 then return end
        check(clicks == 0, "child received a click outside circle")
        if clicks == 0 then io.stderr:write("[PASS] corner click rejected\n") end
        clicks = 0
        click(20, 20)
        return true
    end,
    function(count)
        if count < 5 then return end
        check(clicks == 1, "child did not receive exactly one centre click")
        if clicks == 1 then io.stderr:write("[PASS] centre click delivered\n") end
        click(1, 1, #cases)
        return true
    end,
    function(count)
        if count < 5 then return end
        check(rounded_clicks == 0, "child received a click outside rounded arc")
        if rounded_clicks == 0 then io.stderr:write("[PASS] rounded corner click rejected\n") end
        rounded_clicks = 0
        click(20, 20, #cases)
        return true
    end,
    function(count)
        if count < 5 then return end
        check(rounded_clicks == 1, "rounded child did not receive exactly one centre click")
        if rounded_clicks == 1 then io.stderr:write("[PASS] rounded centre click delivered\n") end
        for _, case in ipairs(cases) do case.bar.visible = false end
        assert(#failures == 0, table.concat(failures, "\n"))
        return true
    end,
}
