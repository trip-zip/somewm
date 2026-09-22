-- Private grid decoration declarations. No widget bindings or layout callbacks:
-- Clay positions every segment. Shape functions only rasterize a solved segment.
local clay = require('wibox.clay')
local shape = require('gears.shape')
local M = {}

function M.axis(widget, axis, count, spacing)
    local p, result = widget._private, {prefix={[0]=0}, count=count}
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
        result[i]={width=width,before=before,after=after,size=before+width+after,
            style=style,outer=outer}
        result.prefix[i]=result.prefix[i-1]+result[i].size
    end
    result.inset=result[1].size+result[count+1].size
    return result
end
function M.gap(axis, first, span)
    return axis.prefix[first+span-1]-axis.prefix[first]
end

-- A capsule or square dash is a filled path, using the existing native shape
-- primitive. Clipping at the segment's solved raster bounds preserves phase
-- across adjacent segments and does not create caps at their artificial edges.
local function stroke(style, vertical, thickness, center, origin)
    local dash = style.dashes
    local pattern,total={},0
    for _,v in ipairs(dash or {}) do
        if type(v)=='number' and v>=0 then pattern[#pattern+1]=v;total=total+v end
    end
    if #pattern%2==1 then
        local n=#pattern
        for i=1,n do pattern[#pattern+1]=pattern[i] end
        total=total*2
    end
    return function(w,h)
        return clay.shape_ops(function(cr)
            local length=vertical and h or w
            local function piece(a,b)
                if b<=a then return end
                local cap=style.caps or 'butt'
                local extra=cap=='butt' and 0 or thickness/2
                local x,y=vertical and center-thickness/2 or a-extra,
                    vertical and a-extra or center-thickness/2
                local ww,hh=vertical and thickness or b-a+2*extra,
                    vertical and b-a+2*extra or thickness
                cr:save();cr:translate(x,y)
                if cap=='round' then shape.rounded_rect(cr,ww,hh,thickness/2)
                else cr:rectangle(0,0,ww,hh) end
                cr:restore()
            end
            if total<=0 then piece(-origin,length);return end
            local offset=(origin+(style.offset or 0))%total
            local start=-offset-total
            while start<length+thickness do
                local pos=start
                for i,v in ipairs(pattern) do
                    if i%2==1 and pos+v>=-thickness and pos<=length+thickness then piece(pos,pos+v) end
                    pos=pos+v
                end
                start=start+total
            end
        end,w,h)
    end
end

-- Gradients use grid-local coordinates, even though each segment is rasterized
-- in its own native box. Translate only the declared color source, not geometry.
local function local_fill(color,x,y)
    local fill=clay.fill(color)
    if fill and (fill.linear or fill.radial) then
        local points=fill.linear or fill.radial
        local second=fill.linear and 3 or 4
        points[1],points[2]=points[1]-x,points[2]-y
        points[second],points[second+1]=points[second]-x,points[second+1]-y
    end
    return fill
end
local function rectangle(w,h) return clay.shape_ops(shape.rectangle,w,h) end

-- Solid borders share native border commands on the real cells.
-- Styled boundaries retain their separately clipped stroke and gradient boxes.
function M.solid_colors(p, fg)
    if next(p.custom_border_width.rows) or next(p.custom_border_width.cols) then return end
    local a = clay.solid_rgba(p.border_color.inner or fg)
    local b = clay.solid_rgba(p.border_color.outer or fg)
    if not a or not b then return end
    for i=1,4 do if a[i] ~= b[i] then return a,b end end
    return a,a
end

function M.painter(p, fg, xs, ys, columns, rows, flow)
    local xstart,ystart={[1]=0},{[1]=0}
    for i,v in ipairs(columns) do xstart[i+1]=xstart[i]+xs[i].size+v end
    for i,v in ipairs(rows) do ystart[i+1]=ystart[i]+ys[i].size+v end
    local occupied={}
    for i,item in ipairs(p.widgets) do
        if (not flow or flow[i]) and item.widget._private.visible ~= false then
            for r=item.row,item.row+item.row_span-1 do
                occupied[r]=occupied[r] or {}
                for c=item.col,item.col+item.col_span-1 do occupied[r][c]=i end
            end
        end
    end
    local function at(r,c) return occupied[r] and occupied[r][c] end
    local function covered(item,index,boundary,a,b,axis)
        local first=axis=='x' and item.col or item.row
        local span=axis=='x' and item.col_span or item.row_span
        if not boundary then return index>=first and index<first+span end
        local left=index-1>=first and index-1<first+span
        local right=index>=first and index<first+span
        return (left and right) or (left and b<=boundary.before)
            or (right and a>=boundary.before+boundary.width)
    end
    -- A tile is either a track or a boundary on each axis. Split only at its
    -- authored spacing/stroke edges, then omit regions cleared by real cells.
    -- All retained regions become ordinary containers, including hole fill.
    return function(c,r,xb,yb)
        local xx,yy=xb and xs[c],yb and ys[r]
        local w,h=xx and xx.size or columns[c],yy and yy.size or rows[r]
        local xp=xx and {0,xx.before,xx.before+xx.width,w} or {0,w}
        local yp=yy and {0,yy.before,yy.before+yy.width,h} or {0,h}
        local ids={}
        for rr=r-(yb and 1 or 0),r do
            for cc=c-(xb and 1 or 0),c do local id=at(rr,cc);if id then ids[id]=true end end
        end
        local lines={}
        for j=1,#yp-1 do
            local cells={}
            for i=1,#xp-1 do
                local a,b,d,e=xp[i],xp[i+1],yp[j],yp[j+1]
                if b>a and e>d then
                    local clear=false
                    for id in pairs(ids) do
                        local item=p.widgets[id]
                        if covered(item,c,xx,a,b,'x') and covered(item,r,yy,d,e,'y') then clear=true;break end
                    end
                    local n={w=b-a,h=e-d}
                    if not clear then
                        local outer=(xx and xx.outer and a>=xx.before and b<=xx.before+xx.width)
                            or (yy and yy.outer and d>=yy.before and e<=yy.before+yy.width)
                        local origin_x=xstart[c]+(xb and 0 or xs[c].size)+a
                        local origin_y=ystart[r]+(yb and 0 or ys[r].size)+d
                        local color=p.border_color[outer and 'outer' or 'inner'] or fg
                        n.bg=clay.solid_rgba(color)
                        if not n.bg then
                            n.fill=local_fill(color,origin_x,origin_y)
                            if n.fill then n.shape=rectangle end
                        end
                        local tail=n
                        -- Custom rows paint before custom columns.
                        for _,entry in ipairs{{yy,false,d,ystart[r]+(yb and 0 or ys[r].size)+d,
                            xstart[c]+(xb and 0 or xs[c].size)+a},
                            {xx,true,a,xstart[c]+(xb and 0 or xs[c].size)+a,
                            ystart[r]+(yb and 0 or ys[r].size)+d}} do
                            local boundary,vertical,offset=entry[1],entry[2],entry[3]
                            if boundary and boundary.style and boundary.width>0 then
                                local color=boundary.style.color or p.border_color[boundary.outer and 'outer' or 'inner'] or fg
                                local paint={w='grow',h='grow',fill=local_fill(color,origin_x,origin_y),
                                    shape=stroke(boundary.style,vertical,boundary.width,
                                        boundary.before+boundary.width/2-offset,entry[5])}
                                tail.children={paint};tail=paint
                            end
                        end
                    end
                    cells[#cells+1]=n
                end
            end
            if yp[j+1]>yp[j] then lines[#lines+1]={dir='x',w=w,h=yp[j+1]-yp[j],children=cells} end
        end
        return {dir='y',w=w,h=h,children=lines}
    end
end
return M
