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
local inset_clicks = 0
local child_with_border = wibox.widget { text = "inset", widget = wibox.widget.textbox }
child_with_border:buttons { awful.button({}, 1, function() inset_clicks = inset_clicks + 1 end) }
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
    { name = "inset path with stroke", width = 80, height = 40,
        widget = wibox.widget {
            { child_with_border, bg = BLUE, border_width = 3,
                border_color = "#00ff00", widget = wibox.container.background },
            shape = function(ctx, w, h) gshape.rounded_rect(ctx, w - 20, h - 20, 6) end,
            border_width = 2, border_color = "#ffff00",
            bg = RED, widget = wibox.container.background },
        -- The 2px border offsets the 58x18 path by (1,1).
        center = BLUE, center_x = 30, center_y = 10, inset_path = true },
}
local function check_pixels(surface, case, screen_local)
    local before = #failures
    local ox = case.bar.x - (screen_local and s.geometry.x or 0)
    local oy = case.bar.y - (screen_local and s.geometry.y or 0)
    local function pixel(x, y, hex, label, alternate)
        local r, g, b = capture.read(surface, ox + x, oy + y)
        local function matches(color)
            return math.abs(r - tonumber(color:sub(2, 3), 16)) <= 12
                and math.abs(g - tonumber(color:sub(4, 5), 16)) <= 12
                and math.abs(b - tonumber(color:sub(6, 7), 16)) <= 12
        end
        check(matches(hex) or alternate and matches(alternate),
            string.format("%s %s: expected %s%s, got (%d,%d,%d)",
                case.name, label, hex, alternate and " or " .. alternate or "", r, g, b))
    end
    local w, h = case.width, case.height
    pixel(case.center_x or w / 2, case.center_y or h / 2, case.center, "center")
    if case.inset_path then
        pixel(w - 5, h - 5, BG, "outside path bottom-right")
        pixel(w - 5, 5, BG, "outside path right")
        pixel(5, h - 5, BG, "outside path bottom")
        pixel(1, 1, BG, "outside rounded stroke corner")
        pixel(6, 0, "#ffff00", "stroke arc")
        pixel(w / 2 - 10, 0, "#ffff00", "stroke top edge")
        pixel(2, h / 2 - 10, "#00ff00", "child border inside path")
        pixel(w - 21, h / 2 - 10, RED, "exposed right stroke", "#ffff00")
        pixel(w - 2, h / 2 - 10, BG, "child right border outside path")
        pixel(w / 2 - 10, h - 2, BG, "child bottom border outside path")
    else
        local inset = h == 12 and 0 or 1
        pixel(inset, inset, BG, "top-left")
        pixel(w - 1 - inset, inset, BG, "top-right")
        pixel(inset, h - 1 - inset, BG, "bottom-left")
        pixel(w - 1 - inset, h - 1 - inset, BG, "bottom-right")
        if case.nested then pixel(4, 2, BG, "inside inner arc, outside circle") end
    end
    if #failures == before then io.stderr:write("[PASS] " .. case.name .. " pixels\n") end
end
local function click(x, y, index)
    local width, height = root.size()
    awful.spawn { "./build-test/test-virtual-pointer-client", "click",
        tostring(cases[index or 1].bar.x + x), tostring(cases[index or 1].bar.y + y),
        tostring(width), tostring(height) }
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
        for _, case in ipairs(cases) do check_pixels(surface, case) end
        check_pixels(gsurface(s.content), cases[#cases], true)
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
        click(1, 1, #cases - 1)
        return true
    end,
    function(count)
        if count < 5 then return end
        check(rounded_clicks == 0, "child received a click outside rounded arc")
        if rounded_clicks == 0 then io.stderr:write("[PASS] rounded corner click rejected\n") end
        rounded_clicks = 0
        click(20, 20, #cases - 1)
        return true
    end,
    function(count)
        if count < 5 then return end
        check(rounded_clicks == 1, "rounded child did not receive exactly one centre click")
        if rounded_clicks == 1 then io.stderr:write("[PASS] rounded centre click delivered\n") end
        local case = cases[#cases]
        click(case.width - 5, case.height - 5, #cases)
        return true
    end,
    function(count)
        if count < 5 then return end
        check(inset_clicks == 0, "inset child received a click outside path")
        if inset_clicks == 0 then io.stderr:write("[PASS] inset outside click rejected\n") end
        local case = cases[#cases]
        click(case.center_x, case.center_y, #cases)
        return true
    end,
    function(count)
        if count < 5 then return end
        check(inset_clicks == 1, "inset child did not receive exactly one center click")
        if inset_clicks == 1 then io.stderr:write("[PASS] inset center click delivered\n") end
        for _, case in ipairs(cases) do case.bar.x = case.bar.x + 10 end
        awesome._test_redeclare()
        local buffers = awesome._clay_tree(s):match("raster_bytes %d+ buffers (%d+)")
        check(tonumber(buffers) == 0, "moving clipped bars allocated buffers")
        if tonumber(buffers) == 0 then io.stderr:write("[PASS] moving clipped bars allocated zero buffers\n") end
        return true
    end,
    function(count)
        if count < 5 then return end
        local surface = gsurface(s.content)
        for _, case in ipairs(cases) do check_pixels(surface, case, true) end
        for _, case in ipairs(cases) do case.bar.visible = false end
        assert(#failures == 0, table.concat(failures, "\n"))
        return true
    end,
}
