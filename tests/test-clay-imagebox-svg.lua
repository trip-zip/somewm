local runner = require("_runner")
local capture = require("_widget_capture")
local wibox = require("wibox")
local awful = require("awful")
local naughty = require("naughty")
local cairo = require("lgi").cairo
local s = screen[1]
local path = os.tmpname()
local png = path .. ".png"
local file = assert(io.open(path, "w"))
file:write([[<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16"><circle cx="8" cy="8" r="8" fill="red"/></svg>]])
file:close()
local surface = cairo.ImageSurface(cairo.Format.ARGB32, 16, 16)
local cr = cairo.Context(surface)
cr:set_source_rgb(1, 0, 0)
cr:arc(8, 8, 8, 0, 2 * math.pi)
cr:fill()
surface:write_to_png(png)
local bar, image, notification, menu
local cap = capture.new(s, 0, 0, 128, 64)

local function image_boxes()
    local out = {}
    for line in awesome._clay_tree(s):gmatch("[^\n]+") do
        if line:match("^    %x+ ") and line:find(" image ", 1, true) then
            local x, y, w, h = line:match("box (%d+),(%d+) (%d+)x(%d+)")
            if x then out[#out + 1] = { x = tonumber(x), y = tonumber(y),
                width = tonumber(w), height = tonumber(h), line = line } end
        end
    end
    return out
end

local function retry(count, check)
    local ok, err = pcall(check)
    if ok then return true end
    assert(count < 20, err)
end

local steps = {
    function(count)
        if count == 1 then
            image = wibox.widget.imagebox(path)
            bar = wibox { x = 0, y = 0, width = 128, height = 64,
                screen = s, bg = "#101010", visible = true,
                widget = wibox.container.place(image, "left", "top") }
            return
        end
        return retry(count, function()
            local box = assert(image_boxes()[1], "SVG image leaf missing")
            assert(box.line:find(" image 16x16 ", 1, true), box.line)
            cap:assert_pixel(cap:shot(), box.x + math.floor(box.width / 2),
                box.y + math.floor(box.height / 2), "#ff0000", "SVG centre")
        end)
    end,
    function(count)
        if count == 1 then image.forced_width = 64; image.forced_height = 64; return end
        return retry(count, function()
            local box = assert(image_boxes()[1])
            assert(box.width == 64 and box.height == 64, "forced SVG size")
            local shot = cap:shot()
            cap:assert_pixel(shot, box.x + 32, box.y + 32, "#ff0000", "large SVG centre")
            cap:assert_pixel(shot, box.x + 4, box.y + 4, "#101010", "large SVG corner")
        end)
    end,
    function(count)
        if count == 1 then image:set_stylesheet("circle { fill: blue; }"); return end
        return retry(count, function()
            cap:assert_pixel(cap:shot(), 32, 32, "#0000ff", "stylesheet centre")
        end)
    end,
}

for _, settings in ipairs {
    { resize = true, upscale = true, downscale = true, forced_width = 64, forced_height = 64 },
    { resize = false, upscale = true, downscale = true, forced_width = 64, forced_height = 64 },
    { resize = true, upscale = false, downscale = true, forced_width = 64, forced_height = 64 },
    { resize = true, upscale = true, downscale = false, forced_width = 8, forced_height = 8 },
} do
    steps[#steps + 1] = function()
        local function boxes(source)
            local widget = wibox.widget.imagebox(source)
            for k, v in pairs(settings) do widget[k] = v end
            bar.widget = wibox.container.place(widget, "left", "top")
            awesome._test_redeclare()
            return awesome._test_widget_boxes(bar.drawin)
        end
        local vector, raster = boxes(path), boxes(png)
        assert(#vector == #raster and #vector > 0, "SVG and PNG occurrence counts")
        for i, box in ipairs(vector) do
            for _, axis in ipairs { "x", "y", "width", "height" } do
                assert(box[axis] == raster[i][axis], "SVG and PNG " .. axis)
            end
        end
        return true
    end
end

naughty.connect_signal("request::display", function(n)
    require("naughty.layout.box") { notification = n }
end)
steps[#steps + 1] = function(count)
    if count == 1 then
        bar.visible = false
        notification = naughty.notification { title = "SVG", message = "Icon",
            icon = path, timeout = 0 }
        return
    end
    return retry(count, function()
        local box = assert(image_boxes()[1], "notification image leaf missing")
        local r, g, b = capture.read(s.content,
            box.x + math.floor(box.width / 2), box.y + math.floor(box.height / 2))
        assert(r == 255 and g == 0 and b == 0, "notification SVG centre")
    end)
end
steps[#steps + 1] = function(count)
    if count == 1 then
        notification:destroy()
        menu = awful.menu { items = { { "Submenu", { { "Child", function() end } } } },
            theme = { submenu_icon = "icons/lucide/chevron-right.svg",
                bg_normal = "#101010", fg_normal = "#ffffff", height = 32, width = 128 } }
        menu:show { coords = { x = 0, y = 100 } }
        return
    end
    return retry(count, function()
        local box = assert(image_boxes()[1], "submenu arrow image leaf missing")
        local pixels = capture.new(s, box.x, box.y, box.width, box.height)
        local shot = pixels:shot()
        local stroke = false
        for y = 0, box.height - 1 do
            for x = 0, box.width - 1 do
                local r, g, b = pixels:pixel(shot, x, y)
                if r ~= 16 or g ~= 16 or b ~= 16 then stroke = true end
            end
        end
        assert(stroke, "submenu arrow has no stroke")
        menu:hide()
        os.remove(path)
        os.remove(png)
    end)
end
runner.run_steps(steps)
