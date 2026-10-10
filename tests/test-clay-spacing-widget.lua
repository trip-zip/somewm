-- luacheck: globals screen awesome systray_item
local runner = require("_runner")
local capture = require("_widget_capture")
local wibox = require("wibox")
local beautiful = require("beautiful")
local s = screen[1]
local bar, layout, spacer, items
local cap = capture.new(s, 100, 100, 100, 100)

local function setup(vertical, tray)
    spacer = wibox.widget.base.make_widget()
    spacer._clay = { name = "spacing-color", describe = function()
        return { bg = {1, 0, 1, 1} }
    end }
    if tray then
        beautiful.systray_paddings = 0
        items = {systray_item.register(), systray_item.register()}
        for _, item in ipairs(items) do
            item:set_icon_pixmap(16, 16, string.char(255, 255, 0, 0):rep(256))
        end
        for _, item in ipairs(systray_item.get_items()) do
            if item ~= items[1] and item ~= items[2] then item.status = "Passive" end
        end
        layout = wibox.widget.systray()
        layout:_sync_items()
    else
        layout = (vertical and wibox.layout.fixed.vertical or wibox.layout.fixed.horizontal)(
            wibox.widget.textbox("a"), wibox.widget.textbox("b"))
    end
    layout.spacing, layout.spacing_widget = 6, spacer
    if bar then bar.visible = false end
    bar = wibox {x=100,y=100,width=100,height=100,screen=s,visible=true,bg="#101010",
        widget=wibox.container.margin(layout)}
end

local function check(vertical)
    local wired = bar._drawable._clay_wired
    local binding = assert(wired[spacer], "the spacing widget has no occurrence")[1]
    local box = assert(binding.element).box
    assert(box[vertical and "height" or "width"] == 6, "the spacing box is not six pixels")
    local cells = layout:get_children()
    local first = assert(wired[cells[1]])[1].element.box
    local second = assert(wired[cells[2]])[1].element.box
    local axis, size = vertical and "y" or "x", vertical and "height" or "width"
    assert(box[axis] == first[axis] + first[size] and second[axis] == box[axis] + 6,
        "the spacing box is not between the cells")
    assert(awesome._clay_tree(s):find("spacing-color", 1, true), "the dump omits the spacing leaf")
    cap:assert_pixel(cap:shot(), box.x + math.floor(box.width/2),
        box.y + math.floor(box.height/2), "#ff00ff", "the spacing leaf")
    return true
end

runner.run_steps {
    function(count) if count == 1 then setup(false, false); return nil end return check(false) end,
    function(count) if count == 1 then setup(true, false); return nil end return check(true) end,
    function(count) if count == 1 then setup(false, true); return nil end return check(false) end,
    function(count)
        if count == 1 then
            local cairo = require("lgi").cairo
            local image = cairo.ImageSurface(cairo.Format.ARGB32, 16, 16)
            layout = wibox.layout.flex.horizontal(
                wibox.widget.imagebox(image), wibox.widget.imagebox(image))
            layout.spacing, layout.spacing_widget = 6, spacer
            bar.widget = wibox.container.margin(layout)
            return nil
        end
        -- Each image declares the 100 high bound times its aspect; the
        -- spacing widget stays between them.
        local images = {}
        for line in awesome._clay_tree(s):gmatch("[^\n]+") do
            if line:find(" image 16x16 w=fit>=100 user h=fit ", 1, true) then
                local x, y, width, height = line:match("box (%d+),(%d+) (%d+)x(%d+)")
                images[#images + 1] = {x=tonumber(x)-100, y=tonumber(y)-100,
                    width=tonumber(width), height=tonumber(height)}
            end
        end
        assert(#images == 2, "the flex dump does not contain two images declared from the bound")
        assert(images[1].x == 0 and images[2].x == images[1].width + 6,
            "the flex images do not leave a six pixel gap")
        io.stderr:write("[PASS] flex images declare from the height bound around the spacing widget\n")
        return true
    end,
    function() bar.visible = false; return true end,
}
