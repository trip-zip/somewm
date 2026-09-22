-- Shared root wallpaper: first-frame source selection, captures and bands.
-- Fake screens have no renderer; use the existing headless-output hotplug hook.
local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local surface = require('gears.surface')
local capture = require('_widget_capture')
local example = require('_clay_example')
local cairo = require('lgi').cairo
local evidence = os.getenv('SOMEWM_EXAMPLE_EVIDENCE')
local left, right, source_w, source_h, reversed
local pixels = evidence and assert(io.open(evidence..'/pixels.txt','w'))
local function report(message)
    io.stderr:write(message)
    if pixels then pixels:write(message); pixels:flush() end
end

local function command(argv)
    local done, code, errors
    awful.spawn.easy_async(argv, function(_, stderr, _, exit)
        code, errors, done = exit, stderr, true
    end)
    for _ = 1, 500 do
        if done then break end
        async.sleep(0.002)
    end
    assert(done and code == 0, table.concat(argv, ' ') .. ': ' .. tostring(errors))
end

local function wallpaper(reverse)
    source_w, source_h = 0, 0
    for s in screen do
        local g = s.geometry
        source_w = math.max(source_w, g.x + g.width)
        source_h = math.max(source_h, g.y + g.height)
    end
    reversed = reverse
    local p = cairo.Pattern.create_linear(0, 0, source_w, source_h)
    local a, b = {32, 64, 96}, {224, 192, 128}
    if reverse then a, b = b, a end
    p:add_color_stop_rgb(0, a[1]/255, a[2]/255, a[3]/255)
    p:add_color_stop_rgb(1, b[1]/255, b[2]/255, b[3]/255)
    assert(root._wallpaper(p._native))
end

local function pixel(im, px, py, lx, ly, what)
    local r, g, b = capture.read(im, px, py)
    local want = {0, 0, 0}
    if lx >= 0 and ly >= 0 and lx < source_w and ly < source_h then
        local t = math.max(0, math.min(1,
            (lx*source_w + ly*source_h)/(source_w^2 + source_h^2)))
        if reversed then t = 1-t end
        want = {32+192*t, 64+128*t, 96+32*t}
    end
    for i, got in ipairs{r,g,b} do
        assert(math.abs(got-want[i]) <= 3,
            ('%s (%d,%d), source %.2f,%.2f: #%02x%02x%02x channel %d expected %.2f')
                :format(what,px,py,lx,ly,r,g,b,i,want[i]))
    end
    report(('[PASS] %s (%d,%d) source %.2f,%.2f = #%02x%02x%02x\n')
        :format(what,px,py,lx,ly,r,g,b))
end

local function check(name)
    -- Exactly one synchronous frame following the authored change. No pixel
    -- polling or later-frame convergence is allowed before these assertions.
    awesome._test_redeclare()
    local spanning, skipped = surface(root.content()), surface(root.content(true))
    for _, s in ipairs{left,right} do
        local g, scale = s.geometry, s.scale
        local dump = awesome._clay_tree(s)
        assert(dump:find('derived 0',1,true),dump)
        assert(not dump:find('[tree!=scene]',1,true),dump)
        local outputs, images, first = 0, 0
        local realized = false
        for line in dump:gmatch('[^\n]+') do
            assert(not line:match('^%s*BACKGROUND '),line)
            if line:match('^%s*OUTPUT ') then
                outputs = outputs+1
                assert(line:find(' output column image ',1,true),line)
            end
            if line == '  realized:' then realized = true
            elseif realized and not first then first = line end
            if line:find(' IMAGE ',1,true) and line:find(' output ',1,true) then
                images = images+1
                assert(first == line,'wallpaper is not first')
                assert(line:find(('box 0,0 %dx%d'):format(g.width,g.height),1,true),line)
                local bytes = tonumber(assert(line:match('raster=(%d+)')))
                local w,h = math.floor(g.width*scale+0.5),math.floor(g.height*scale+0.5)
                assert(bytes == w*h*4,'raster must be output-sized: '..line)
                report(('[PASS] %s %s OUTPUT raster=%d (%dx%d device)\n')
                    :format(name,s.output.name,bytes,w,h))
            end
        end
        assert(outputs == 1 and images == 1,'expected one OUTPUT IMAGE per output')
        local shot = surface(s.content)
        for _, p in ipairs{{0,0},{g.width-1,g.height-1}} do
            local x,y = p[1],p[2]
            pixel(shot,x,y,g.x+x+0.5,g.y+y+0.5,name..' screen '..s.output.name)
            pixel(spanning,g.x+x,g.y+y,g.x+x+0.5,g.y+y+0.5,name..' root '..s.output.name)
            local _,_,_,a = capture.read(skipped,g.x+x,g.y+y)
            assert(a == 0,'root.content(true) must skip wallpaper')
        end
        example.save(name..'-'..s.output.name,dump)
    end
    if evidence then skipped:write_to_png(evidence..'/'..name..'-skipped.png') end
end

runner.run_async(function()
    left = screen[1]
    left.output.position = {x=0,y=0}
    assert(awesome._test_add_output(640,480))
    for _ = 1, 500 do
        if screen.count() == 2 then break end
        async.sleep(0.002)
    end
    assert(screen.count() == 2)
    for s in screen do if s ~= left then right = s end end
    right.output.position = {x=left.geometry.width+160,y=160}
    wallpaper(false)
    check('initial')
    right.output.position = {x=left.geometry.width+40,y=40}
    check('moved')

    -- Headless outputs have no advertised modes for output.mode; the existing
    -- output-management protocol accepts a custom physical mode.
    command{'wlr-randr','--output',right.output.name,'--custom-mode','480x360'}
    assert(right.geometry.width == 480 and right.geometry.height == 360)
    check('resized')
    right.scale = 1.25
    assert(right.scale == 1.25 and left.scale == 1)
    check('scaled')
    local path = evidence and evidence..'/scaled-device.png' or os.tmpname()..'.png'
    command{'grim','-o',right.output.name,'-s','1.25',path}
    local device = surface(path)
    local g = right.geometry
    local w,h = device:get_width(),device:get_height()
    assert(w == 480 and h == 360,'device capture must retain output density')
    for _, p in ipairs{{0,0},{w-1,h-1}} do
        pixel(device,p[1],p[2],g.x+(p[1]+0.5)/1.25,g.y+(p[2]+0.5)/1.25,'scaled device')
    end
    if not evidence then os.remove(path) end
    -- Paint a source that extends past the fractional output's far edge;
    -- this separates replacement selection from Cairo's transparent-edge filter.
    right.scale = 1
    wallpaper(true)
    right.scale = 1.25
    check('replaced')
    right.output.position = {x=source_w+40,y=40}
    check('past-source')
    report('[PASS] layout growth retains the transparent source edge until a new wallpaper call\n')
    right.scale = 1
    wallpaper(false)
    check('repaint-grown-layout')
    assert(awesome._test_redeclare() == 0,'unchanged wallpaper frame must not mutate')
    for _, s in ipairs{left,right} do
        local dump = awesome._clay_tree(s)
        assert(dump:find('buffers 0',1,true),dump)
        example.save('unchanged-'..s.output.name,dump)
    end
    if pixels then pixels:close() end
    runner.done()
end)
