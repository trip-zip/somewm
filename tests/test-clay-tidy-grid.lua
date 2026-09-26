-- Public grid inputs for all19 accepted shared-track shapes.
local wibox = require('wibox')
local tidy = require('_clay_tidy')
local example = require('_clay_example')
local cases = {}
local colors = {'#ff0000', '#00ff00', '#0000ff', '#ffff00',
    '#ff00ff', '#00ffff', '#808080'}

local function grid(args)
    local g = wibox.layout.grid()
    g.spacing = 5
    g.minimum_column_width = 10
    g.minimum_row_height = 10
    for key, value in pairs(args or {}) do g[key] = value end
    return g
end

local function leaves(g, specs)
    local widgets = {}
    for i, spec in ipairs(specs) do
        local widget = tidy.leaf(spec[1], spec[2], colors[i] or '#808080')
        if spec[3] then
            g:add_widget_at(widget, spec[3], spec[4], spec[5], spec[6])
        else
            g:add(widget)
        end
        widgets[#widgets + 1] = widget
    end
    return widgets
end

local function add(name, args, specs, extent, allocations, prepare)
    cases[#cases + 1] = {
        name = 'tidy-grid-' .. name,
        create = function()
            local g = grid(args)
            local widgets = leaves(g, specs)
            if prepare then prepare(g, widgets) end
            return { popup = tidy.popup(g), grid = g, widgets = widgets }
        end,
        verify = function(state, dump)
            if not extent then return end
            local x, y, width, height = dump:match(
                'wibox%.layout%.grid[^\n]- box (%-?%d+),(%-?%d+) (%d+)x(%d+)')
            assert(x, 'grid has no actual solved box')
            x, y = tonumber(x), tonumber(y)
            assert(tonumber(width) == extent[1] and tonumber(height) == extent[2],
                name .. ': expected grid ' .. extent[1] .. 'x' .. extent[2]
                    .. ', got ' .. width .. 'x' .. height)
            for i, area in ipairs(allocations or {}) do
                local px, py = x + area[1] + math.floor(area[3] / 2),
                    y + area[2] + math.floor(area[4] / 2)
                example.pixel(px, py, colors[i])
                local found
                for _, hit in ipairs(state.popup:find_widgets(
                        px - state.popup.x, py - state.popup.y)) do
                    if hit.widget == state.widgets[i] then
                        assert(hit.width == area[3] and hit.height == area[4],
                            name .. ': original widget has wrong allocation')
                        found = true
                    end
                end
                assert(found, name .. ': original widget absent from its painted area')
            end
        end,
    }
end

local unequal = {{40,10}, {70,20}, {20,30}, {30,10}}
add('homogeneous-content', {column_count=2}, {{40,10}, {70,10}}, {145,10},
    {{0,0,70,10}, {75,0,70,10}})
add('content-both-axes', {column_count=2, homogeneous=false}, unequal, {115,55},
    {{0,0,40,20}, {45,0,70,20}, {0,25,40,30}, {45,25,70,30}})
add('homogeneous-both-axes', {column_count=2}, unequal, {145,65},
    {{0,0,70,30}, {75,0,70,30}, {0,35,70,30}, {75,35,70,30}})
add('expanded-uniform', {column_count=2, spacing=0, forced_width=200,
    forced_height=80, expand=true}, unequal, {200,80},
    {{0,0,100,40}, {100,0,100,40}, {0,40,100,40}, {100,40,100,40}})
add('independent-axes', {column_count=2, homogeneous=false, forced_width=225,
    forced_height=80, expand={horizontal=true, vertical=false}}, unequal, {225,80},
    {{0,0,80,20}, {85,0,140,20}, {0,25,80,30}, {85,25,140,30}})
-- No requested track extent in the empty default case.
add('empty', {minimum_column_width=0, minimum_row_height=0}, {})
add('empty-minima', {column_count=3, row_count=2}, {}, {40,25})
add('one-item', {column_count=3, minimum_row_height=20}, {{40,20}}, {130,20},
    {{0,0,40,20}})
add('two-items', {column_count=3, minimum_row_height=20}, {{40,20}, {70,20}}, {220,20},
    {{0,0,70,20}, {75,0,70,20}})
add('seven-items', {column_count=3, minimum_row_height=20, forced_width=300,
    expand={horizontal=true, vertical=false}},
    {{10,20}, {10,20}, {10,20}, {10,20}, {10,20}, {10,20}, {10,20}}, {300,70},
    {{0,0,96,20}, {101,0,96,20}, {202,0,96,20}, {0,25,96,20},
        {101,25,96,20}, {202,25,96,20}, {0,50,96,20}})
add('intentional-holes', {column_count=3, homogeneous=false},
    {{40,10,1,1}, {30,10,1,3}, {20,20,2,2}}, {100,35},
    {{0,0,40,10}, {70,0,30,10}, {45,15,20,20}})
add('column-spans', {column_count=3, forced_width=300,
    homogeneous={horizontal=true, vertical=false},
    expand={horizontal=true, vertical=false}},
    {{100,10,1,1,1,3}, {70,20,2,1,1,2}, {30,20,2,3},
        {20,10,3,1}, {80,10,3,2,1,2}}, {300,50},
    {{0,0,298,10}, {0,15,197,20}, {202,15,96,20}, {0,40,96,10}, {101,40,197,10}})
add('row-spans', {homogeneous=false},
    {{40,55,1,1,2,1}, {70,20,1,2}, {30,30,2,2}, {100,10,3,1,1,2}}, {123,75},
    {{0,0,48,60}, {53,0,70,25}, {53,30,70,30}, {0,65,123,10}})
add('wrapped-text', {column_count=2, forced_width=90,
    homogeneous={horizontal=true, vertical=false},
    expand={horizontal=true, vertical=false}}, {}, nil, nil, function(g, widgets)
        for _, value in ipairs{'aa aa aa', 'bb bb bb bb', 'cc cc', 'dd'} do
            local text = wibox.widget.textbox(value)
            text.wrap = 'word'
            widgets[#widgets + 1] = text
            g:add(text)
        end
    end)
local squares = {{20,20}, {20,20}, {20,20}, {20,20}}
add('borders', {column_count=2, border_width={inner=1,outer=1},
    border_color='#ffffff'}, squares, {63,63},
    {{6,6,20,20}, {37,6,20,20}, {6,37,20,20}, {37,37,20,20}})
add('border-span-hole', {column_count=2, minimum_column_width=20,
    minimum_row_height=20, border_width={inner=1,outer=1}, border_color='#ffffff'},
    {{20,20,1,1,1,2}, {20,20,2,1}}, {63,63}, {{6,6,51,20}, {6,37,20,20}})
add('custom-border', {column_count=2, border_width={inner=1,outer=2},
    border_color='#ffffff'}, squares, {67,65},
    {{7,7,20,20}, {40,7,20,20}, {7,38,20,20}, {40,38,20,20}}, function(g)
        g:add_column_border(2, 3, {color='#00ffff', dashes={4,2}, dash_offset=1, caps='round'})
    end)
add('native-overlap', {column_count=2, homogeneous=false, superpose=true},
    {{40,20}, {70,20}}, {115,20}, nil, function(g, widgets)
        local float = tidy.leaf(0, 0, '#0000ff')
        float.forced_width, float.forced_height = 200, 60
        g:add_widget_at(float, 1, 2)
        widgets[#widgets + 1] = float
    end)
add('nested', {column_count=2, homogeneous=false}, {}, {75,45}, nil, function(g)
    for _, size in ipairs{10,20} do
        local inner = grid{column_count=2}
        leaves(inner, {{size,size}, {size,size}, {size,size}, {size,size}})
        g:add(inner)
    end
end)

assert(#cases == 19)
tidy.run(cases)
