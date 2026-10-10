-- Grid borders as authored cell edges: each boundary's width, its colour and
-- the spacing on either side of it. Clay draws them as native borders.
local clay = require('wibox.clay')
local M = {}

function M.axis(widget, axis, count, spacing)
    local p, result = widget._private, {}
    local custom = p.custom_border_width[axis]
    for i=1,count+1 do
        local outer = i==1 or i==count+1
        local style = custom[i]
        local width = style and style.size
        if width == nil then width=p.border_width[outer and 'outer' or 'inner'] end
        width=clay.pixels(widget,'border_width',width)
        local before = i>1 and (width>0 and spacing or math.floor(spacing/2)) or 0
        local after = i<=count and (width>0 and spacing or math.ceil(spacing/2)) or 0
        if outer and width==0 then before,after=0,0 end
        result[i]={width=width,before=before,after=after,style=style,outer=outer}
    end
    return result
end

local function color(widget, p, fg, boundary)
    local style = boundary.style
    if style and style.dashes and #style.dashes > 0 then
        clay.ignore(widget, 'dashes', 'is drawn as a solid line')
    end
    local rgba = clay.solid_rgba(style and style.color
        or p.border_color[boundary.outer and 'outer' or 'inner'] or fg)
    if not rgba then clay.ignore(widget, 'border_color', 'is not a solid color and is transparent') end
    return rgba
end

-- The cell at column `c` spanning `span` columns in row `r`: its left and top
-- boundaries, its right and bottom ones on the last column and row, and the
-- spacing inside them as padding. Edges of one colour share a node; a cell
-- with several colours nests one node per colour, the outer boundary's
-- colour outermost. A hole is filled with the inner colour.
function M.cell(widget, p, fg, cell, xs, ys, c, span, r, hole)
    local edges = {xs[c], c+span==#xs and xs[#xs] or nil, ys[r], r+1==#ys and ys[#ys] or nil}
    local pad = {xs[c].after, xs[c+span].before, ys[r].after, ys[r+1].before}
    local groups, order = {}, {}
    for i=1,4 do
        local edge = edges[i]
        if edge and edge.width > 0 then
            pad[i] = pad[i] + edge.width
            local rgba = color(widget, p, fg, edge)
            if rgba then
                local key = table.concat(rgba, ',')
                if not groups[key] then
                    groups[key] = {color=rgba, bw={0,0,0,0}}
                    order[#order+1] = key
                end
                groups[key].bw[i] = edge.width
                groups[key].outer = groups[key].outer or edge.outer
            end
        end
    end
    local nested = {}
    for _, outer in ipairs{true, false} do
        for _, key in ipairs(order) do
            if not groups[key].outer == not outer then nested[#nested+1] = groups[key] end
        end
    end
    if hole then cell.bg = clay.solid_rgba(p.border_color.inner or fg) end
    for i=1,#nested-1 do
        for side=1,4 do pad[side] = pad[side] - nested[i].bw[side] end
    end
    cell.pad = pad
    if #nested > 0 then cell.border, cell.bw = nested[#nested].color, nested[#nested].bw end
    if #nested < 2 then return cell end
    local node = cell
    local w, wmin, wsrc = cell.w, cell.wmin, cell.wsrc
    cell.w, cell.wmin, cell.wsrc = 'grow', nil, nil
    for i=#nested-1,1,-1 do
        local group = nested[i]
        node = {w='grow', h='grow', pad=group.bw, border=group.color, bw=group.bw, children={node}}
    end
    node.w, node.wmin, node.wsrc, node.cell = w, wmin, wsrc, true
    return node
end

return M
