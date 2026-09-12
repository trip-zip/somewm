-- Late handwritten regression goldens for every task-2 doc-2 example.
local runner = require('_runner')
local awful = require('awful')
local wibox = require('wibox')
local example = require('_clay_example')
local s = screen[1]
local bars, steps, last = {}, {}, nil
local function text(value) return wibox.widget.textbox(value or 'bar') end
local function bar(args)
    args.screen = s
    args.bg = args.bg or '#00ff00'
    args.widget = args.widget or text()
    local b = awful.wibar(args)
    bars[#bars + 1] = b
    return b
end
local function add(name, setup, verify)
    steps[#steps + 1] = function()
        for _, b in ipairs(bars) do b:remove() end
        bars = {}
        require('gears.wallpaper').set('#123456')
        setup()
        last = nil
        return true
    end
    steps[#steps + 1] = function(n)
        local dump = awesome._clay_tree(s)
        if dump ~= last or not dump:find('converted', 1, true) then
            last = dump
            assert(n < 30, name .. ' did not settle')
            return
        end
        -- Once settled, a differing golden fails immediately at its first line.
        example.check(name, dump)
        verify()
        io.stderr:write('[PASS] ' .. name .. ': golden, solved boxes and pixels\n')
        return true
    end
end
add('most-basic-representation-per-screen', function()
    bar{position='top', height=28}
end, function()
    assert(s.workarea.y == 28 and s.workarea.height == 692)
    example.pixel(100, 14, '#00ff00'); example.pixel(100, 40, '#123456')
end)
add('add-some-wibar-widgets', function()
    local b = bar{position='top', height=28}
    b:setup{layout=wibox.layout.align.horizontal, expand='outside',
        {layout=wibox.layout.fixed.horizontal, text('menu'), text('tags')},
        text('clock'), text('status')}
end, function()
    example.pixel(100, 14, '#00ff00'); example.pixel(100, 40, '#123456')
end)
add('multiple-wibars', function()
    bar{position='top', height=20, bg='#ff0000', widget=text('top')}
    bar{position='bottom', height=20, bg='#ffff00', widget=text('bottom')}
    bar{position='left', width=30, bg='#00ff00', widget=text('left')}
    bar{position='right', width=30, bg='#0000ff', widget=text('right')}
end, function()
    local wa = s.workarea
    assert(wa.x == 30 and wa.y == 20 and wa.width == 1220 and wa.height == 680)
    example.pixel(100,10,'#ff0000'); example.pixel(100,710,'#ffff00')
    example.pixel(15,100,'#00ff00'); example.pixel(1265,100,'#0000ff')
    example.pixel(40,100,'#123456')
end)
add('adding-a-background-to-clay-trees', function()
    bar{position='top', height=28}
    -- Exercise OUTPUT's image, not only its solid background path.
    local cairo = require('lgi').cairo
    local image = cairo.ImageSurface.create(cairo.Format.ARGB32,1280,720)
    local cr = cairo.Context(image)
    cr:set_source_rgb(1,0,0); cr:paint()
    cr:set_source_rgb(0,0,1); cr:rectangle(640,0,640,720); cr:fill()
    require('gears.wallpaper').set(image)
end, function()
    example.pixel(100,14,'#00ff00'); example.pixel(100,100,'#ff0000')
    example.pixel(1000,100,'#0000ff')
end)
add('gaps-bar', function()
    bar{position='top', height=28, margins={left=4,right=6,top=8,bottom=2}}
end, function()
    assert(s.workarea.y == 38)
    example.pixel(100,4,'#123456'); example.pixel(2,20,'#123456')
    example.pixel(100,20,'#00ff00'); example.pixel(100,37,'#123456')
    example.pixel(1276,20,'#123456')
end)
add('ontop-wibar', function()
    bar{position='top', height=28, ontop=true}
end, function()
    assert(s.workarea.y == 0 and s.workarea.height == 720)
    example.pixel(100,14,'#00ff00'); example.pixel(100,40,'#123456')
end)
steps[#steps+1] = function() for _, b in ipairs(bars) do b:remove() end; return true end
runner.run_steps(steps)
