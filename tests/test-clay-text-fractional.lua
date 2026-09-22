-- Nongrid fractional ellipsizing regression. Run each scale in a fresh private compositor:
-- SOMEWM_TEXT_TEST_SCALE=1 / 1.5 / 2. Native tests provide independent Pango
-- references; this checks actual textbox pixels, clips and original lookup.
local runner = require('_runner')
local async = require('_async')
local wibox = require('wibox')
local capture = require('_widget_capture')
local example = require('_clay_example')

runner.run_async(function()
    local s = screen[1]
    s.scale = tonumber(os.getenv('SOMEWM_TEXT_TEST_SCALE') or '1.5')
    async.sleep(.2)
    local function save(name)
        example.save(name, awesome._clay_tree(s))
        local dir = os.getenv('SOMEWM_EXAMPLE_EVIDENCE')
        if dir and os.getenv('SOMEWM_TEXT_SCREENCOPY') then
            local done, status
            require('awful').spawn.easy_async({'grim', '-s', tostring(s.scale),
                dir..'/'..name..'-physical.png'}, function(_, err, _, code)
                status = code
                done = true
                if code ~= 0 then io.stderr:write(err) end
            end)
            assert(async.wait_for_condition(function() return done end, 5))
            assert(status == 0, 'private output screencopy failed')
        end
    end
    local row = wibox.layout.fixed.horizontal()
    row.spacing = 5
    local labels = {}
    for _, text in ipairs{'Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa', 'Su'} do
        local tb = wibox.widget.textbox(text)
        tb.font = 'monospace 10'
        tb.halign = 'right'
        tb.valign = 'center'
        labels[#labels + 1] = tb
        row:add(tb)
    end
    local bar = wibox{screen=s, x=10, y=20, width=600, height=24,
        bg='#101010', fg='#ffffff', visible=true, widget=row}
    -- screen.content is a logical-resolution scene readback (objects/screen.c).
    local cap = capture.new(s, 10, 20, 600, 24)
    local function lookup()
        local result = {}
        assert(bar._drawable._clay_tree == bar._drawable._clay_stored.tree)
        for _, tb in ipairs(labels) do
            local element = assert(bar._drawable._clay_wired[tb][1].element)
            local b = assert(element.box)
            -- Published boxes are host-local. Query original objects, not IDs.
            local found = false
            for _, hit in ipairs(bar:find_widgets(b.x+b.width/2, b.y+b.height/2)) do
                if hit.widget == tb then found = true end
            end
            assert(found, 'original textbox is absent from lookup: '..tb.text)
            result[#result+1] = table.concat({b.x,b.y,b.width,b.height}, ',')
        end
        return table.concat(result, ';')
    end
    async.sleep(.3)
    local before, boxes = cap:shot(), lookup()
    local ink = 0
    for y = 0, cap.height-1 do
        for x = 0, cap.width-1 do
            local r = cap:pixel(before, x, y)
            if r > 0x40 then ink = ink+1 end
        end
    end
    assert(ink > 50, 'text pixel comparison is empty')
    save('fit-end')
    for _, tb in ipairs(labels) do tb.ellipsize = 'none' end
    async.sleep(.3)
    assert(cap:shot() == before, 'fitting text differs when ellipsizing is disabled')
    assert(lookup() == boxes, 'lookup changed when only ellipsize changed')
    save('fit-none')

    -- Real clipping must survive: a single word cannot wrap into the host.
    local tb = labels[1]
    tb.text = 'September'
    tb.halign = 'left'
    bar.widget = tb
    bar.width = 30
    tb.ellipsize = 'end'
    async.sleep(.3)
    local clipped = cap:shot()
    save('clip-end')
    tb.ellipsize = 'none'
    async.sleep(.3)
    assert(cap:shot() ~= clipped, 'genuinely clipped text never ellipsized')
    save('clip-none')
    -- Outside the host must remain identical with either text mode.
    local uncropped = cap:shot()
    for y = 0, cap.height-1 do
        local offset = (y*cap.width+30)*4+1
        local length = (cap.width-30)*4
        assert(uncropped:sub(offset, offset+length-1) == clipped:sub(offset, offset+length-1),
            'text escaped the host clip')
    end
    bar.width = 300
    tb.ellipsize = 'end'
    async.sleep(.3)
    local restored = cap:shot()
    save('restored-end')
    tb.ellipsize = 'none'
    async.sleep(.3)
    assert(cap:shot() == restored, 'obsolete ellipsis survived expansion')
    save('restored-none')
    bar.visible = false
    io.stderr:write('[PASS] nongrid fractional pixels, real clip, resize and original lookup scale=', s.scale, '\n')
    runner.done()
end)
