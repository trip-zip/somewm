-- An empty text or image contributes no element, and no childGap with it.
-- The widget stays subscribed, so a value declares its element again in the
-- same place, and a purposeful spacer and a hidden child are unaffected.
local runner = require('_runner')
local async = require('_async')
local wibox = require('wibox')
local clay = require('wibox.clay')
local capture = require('_widget_capture')
local cairo = require('lgi').cairo

local BX, BY, BW, BH = 100, 100, 400, 24
local s = screen[1]
local cap = capture.new(s, BX, BY, BW, BH)

local function square(color)
    local image = cairo.ImageSurface(cairo.Format.ARGB32, 16, 16)
    local cr = cairo.Context(image)
    cr:set_source_rgb(color == 'red' and 1 or 0, color == 'green' and 1 or 0, 0)
    cr:paint()
    return image
end

-- The bar's widget nodes: class, box and the widget objects bound to each.
local function nodes(bar)
    local want = string.format('  drawin screen %d %dx%d+%d+%d ', s.index,
        bar.drawin.width, bar.drawin.height, bar.drawin.x, bar.drawin.y)
    local head, out = nil, {}

    for line in awesome._clay_tree(s):gmatch('[^\n]+') do
        if head then
            local class = line:match('^    %x+ *([%w_.-]+)')
            if not class then break end
            local x, y, w, h = line:match('box (%-?%d+),(%-?%d+) (%d+)x(%d+)')
            out[#out + 1] = { class = class, line = line, x = tonumber(x),
                y = tonumber(y), width = tonumber(w), height = tonumber(h) }
        elseif line:sub(1, #want) == want then
            head = line
        end
    end
    return out
end

local function classes(bar)
    local out = {}
    for _, node in ipairs(nodes(bar)) do out[#out + 1] = node.class end
    return table.concat(out, ' ')
end

local function node_of(bar, class)
    for _, node in ipairs(nodes(bar)) do
        if node.class == class then return node end
    end
end

runner.run_async(function()
    require('beautiful').font = 'monospace 10'
    local kept = {}
    local icon, empty, label = wibox.widget.imagebox(), wibox.widget.textbox(''),
        wibox.widget.textbox('AB')
    local spacer = wibox.widget.base.make_widget(nil, nil, {enable_properties = true})
    clay.describe_widget(spacer, function()
        return { hmin = 16, bg = clay.solid_rgba('#00ff00') }
    end, 'spacer')
    spacer.forced_width = 20
    local hidden = wibox.widget.textbox('hidden')
    hidden.visible = false
    local row = wibox.layout.fixed.horizontal(icon, empty, label, spacer, hidden)
    row.spacing = 4
    local bar = wibox { x = BX, y = BY, width = BW, height = BH, screen = s,
        bg = '#000080', visible = true, widget = row }
    kept[#kept + 1] = bar
    async.sleep(0.2)

    -- Nothing stands in for the empty text, the empty image or the hidden
    -- child: the row is the label, the spacer, and one gap between them.
    local base = classes(bar)
    assert(base == 'wibox.layout.fixed wibox.widget.textbox text spacer',
        'the empty and hidden widgets left something behind: ' .. base)
    local label_box = assert(node_of(bar, 'wibox.widget.textbox'))
    local spacer_box = assert(node_of(bar, 'spacer'))
    assert(label_box.x == BX and spacer_box.x == BX + label_box.width + 4,
        string.format('label at %d, spacer at %d', label_box.x, spacer_box.x))
    -- The spacer allocation: told 20 wide, grown down its authored
    -- 16px minimum to the row it is in.
    assert(spacer_box.width == 20 and spacer_box.height == BH,
        string.format('spacer %dx%d', spacer_box.width, spacer_box.height))
    local shot = cap:shot()
    cap:assert_pixel(shot, label_box.width + 4 + 10, 12, '#00ff00', 'the spacer')
    cap:assert_pixel(shot, label_box.width + 2, 12, '#000080', 'the single gap')
    io.stderr:write('[PASS] empty and hidden widgets contribute nothing\n')

    -- Present: each one declares an element at the head of the row, moving
    -- the rest along by its width and one gap, and paints there.
    for _, step in ipairs {
        { name = 'text', set = function() empty.text = 'X' end,
          clear = function() empty.text = '' end, class = 'wibox.widget.textbox' },
        { name = 'image', set = function() icon.image = square('red') end,
          clear = function() icon.image = nil end, class = 'image' },
    } do
        step.set()
        async.sleep(0.2)
        local present = nodes(bar)
        local added = node_of(bar, step.class)
        assert(added and added.x == BX and added.width > 0,
            step.name .. ' declared no element of its own')
        assert(#present == #nodes(bar), step.name .. ' did not settle')
        local moved = assert(node_of(bar, 'spacer'))
        assert(moved.x == spacer_box.x + added.width + 4,
            string.format('%s moved the spacer to %d, want %d', step.name,
                moved.x, spacer_box.x + added.width + 4))
        -- The element is a real lookup area for its own original object.
        local found = false
        for _, hit in ipairs(bar:find_widgets(added.x - BX + 1, added.y - BY + 1)) do
            found = found or hit.widget == (step.name == 'text' and empty or icon)
        end
        assert(found, step.name .. ' element is not a lookup area')
        if step.name == 'image' then
            cap:assert_pixel(cap:shot(), added.x - BX + 8, added.y - BY + 8,
                '#ff0000', 'the restored image')
        end

        step.clear()
        async.sleep(0.2)
        assert(classes(bar) == base, step.name .. ' left an element behind: ' .. classes(bar))
        local back = assert(node_of(bar, 'spacer'))
        assert(back.x == spacer_box.x and back.width == spacer_box.width,
            step.name .. ' did not restore the row')
        io.stderr:write('[PASS] ' .. step.name .. ' zero, present and zero again\n')
    end

    -- An empty tray still reserves its icon square inside its padding.
    require('beautiful').systray_paddings = 2
    for _, item in ipairs(systray_item.get_items()) do item.status = 'Passive' end
    local tray = wibox.widget.systray()
    tray:set_base_size(24)
    tray:_update_icon_sizes()
    tray:_sync_items()
    local trayed = wibox { x = BX, y = BY + 40, width = 200, height = 40, screen = s,
        bg = '#000080', visible = true,
        widget = wibox.layout.fixed.horizontal(tray) }
    kept[#kept + 1] = trayed
    async.sleep(0.2)
    local extent = assert(node_of(trayed, 'wibox.widget.systray'))
    assert(extent.width == 28,
        'the empty tray extent is ' .. extent.width .. ', want 28')
    io.stderr:write('[PASS] an empty tray keeps its extent\n')

    bar.visible, trayed.visible = false, false
    runner.done()
end)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
