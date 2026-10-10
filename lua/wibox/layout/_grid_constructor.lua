-- A grid is a column of rows of cells, declared once from authored values
-- and solved by Clay. On a homogeneous axis whose size its ancestors decide,
-- each cell takes its share of that size; otherwise a cell takes its content,
-- with the minimum as its floor, and grows on an expanding axis.
local clay = require('wibox.clay')
local borders = require('wibox.layout._grid_borders')
local constructor = {}

local function sizing(widget, homogeneous, expand, decided, minimum)
    if homogeneous and decided then
        return function(span, count) return {percent=span/count}, nil, 'user' end
    end
    if homogeneous then
        clay.ignore(widget, 'homogeneous', 'is inside a content-sized box: cells take their content size')
    end
    local size, floor = expand and not homogeneous and 'grow' or 'fit', minimum > 0 and minimum or nil
    return function() return size, floor, floor and 'user' end
end

function constructor.describe(widget, fg, _, _, offer)
    local p = widget._private
    if p.num_rows == 0 and p.num_cols == 0 and not p.forced_width and not p.forced_height
            and not p.has_border
            and not next(p.custom_border_width.rows) and not next(p.custom_border_width.cols) then
        return {}
    end
    -- Authored order decides which widget is off the flow: one that meets an
    -- earlier widget in its first row floats over the cell it starts in.
    local taken, overlays = {}, {}
    for i, item in ipairs(p.widgets) do
        if item.row_span > 1 then clay.ignore(widget, 'row_span', 'occupies its first row only') end
        local row = taken[item.row] or {}
        taken[item.row] = row
        local free = true
        for c = item.col, item.col+item.col_span-1 do free = free and not row[c] end
        if free then
            for c = item.col, item.col+item.col_span-1 do row[c] = i end
        else
            overlays[#overlays+1] = item
        end
    end
    local xgap = clay.pixels(widget, 'horizontal_spacing', p.horizontal_spacing)
    local ygap = clay.pixels(widget, 'vertical_spacing', p.vertical_spacing)
    local decorated = p.has_border or next(p.custom_border_width.rows) or next(p.custom_border_width.cols)
    local xs = decorated and borders.axis(widget, 'cols', p.num_cols, xgap)
    local ys = decorated and borders.axis(widget, 'rows', p.num_rows, ygap)
    local width = sizing(widget, p.horizontal_homogeneous, p.horizontal_expand,
        p.forced_width or offer.wdecided, clay.pixels(widget, 'min_cols_size', p.min_cols_size))
    local height = sizing(widget, p.vertical_homogeneous, p.vertical_expand,
        p.forced_height or offer.hdecided, clay.pixels(widget, 'min_rows_size', p.min_rows_size))
    local rows, at = {}, {}
    for r = 1, p.num_rows do
        local cells, c = {}, 1
        at[r] = {}
        while c <= p.num_cols do
            local item = taken[r] and taken[r][c] and p.widgets[taken[r][c]]
            local span = item and item.col_span or 1
            local w, wmin, wsrc = width(span, p.num_cols)
            local cell = {cell=true, w=w, wmin=wmin, wsrc=wsrc, h='grow',
                children=item and {{widget=item.widget, w='grow', h='grow'}} or {}}
            if decorated then
                cell = borders.cell(widget, p, fg, cell, xs, ys, c, span, r,
                    not item or item.widget._private.visible == false)
            end
            cells[#cells+1] = cell
            for k = c, c+span-1 do at[r][k] = cell end
            c = c + span
        end
        local h, hmin, hsrc = height(1, p.num_rows)
        rows[r] = {dir='x', gap=not decorated and xgap or nil, w='grow', h=h, hmin=hmin, hsrc=hsrc,
            children=cells}
    end
    -- _attach is a current-tree reference, resolved by the bridge to Clay's
    -- element attachment, never a stored rectangle.
    for _, item in ipairs(overlays) do
        rows[#rows+1] = {widget=item.widget, float=true, _attach=at[item.row][item.col], w='fit', h='fit'}
    end
    return {dir='y', gap=not decorated and ygap or nil, specs=rows}
end

return constructor
