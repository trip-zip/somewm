-- Shared grid sizing. Clay owns every box and position; these phases
-- change sizing declarations of the original content, never a measurement copy.
local clay = require('wibox.clay')
local constructor = {}
local borders = require('wibox.layout._grid_borders')
local function gaps(gap,first,span)
    return type(gap)=='table' and borders.gap(gap,first,span) or (span-1)*gap
end
local function inset(gap) return type(gap)=='table' and gap.inset or 0 end

-- Range chmax tags: O(log tracks) per span, O(tracks) materialization. A span
-- contributes ceil((requirement - internal gaps) / span) to each covered track.
local function requirements(items, samples, axis, count, minimum, gap, rigid)
    local tags = {}
    local function add(k, lo, hi, first, last, value)
        if first <= lo and hi <= last then tags[k] = math.max(tags[k] or 0, value); return end
        local mid = math.floor((lo + hi) / 2)
        if first <= mid then add(k*2,lo,mid,first,last,value) end
        if last > mid then add(k*2+1,mid+1,hi,first,last,value) end
    end
    for i, item in ipairs(items) do
        local sample = samples[i]
        if sample and (not rigid or not sample.flexible) then
            local start = axis == 'width' and item.col or item.row
            local span = axis == 'width' and item.col_span or item.row_span
            add(1,1,count,start,start+span-1,math.ceil((sample[axis]-gaps(gap,start,span))/span))
        end
    end
    local result = {}
    local function collect(k, lo, hi, value)
        value = math.max(value, tags[k] or 0)
        if lo == hi then result[lo] = value; return end
        local mid = math.floor((lo+hi)/2)
        collect(k*2,lo,mid,value); collect(k*2+1,mid+1,hi,value)
    end
    if count > 0 then collect(1,1,count,minimum) end
    return result
end

local function tracks(natural, count, minimum, homogeneous, expand, extent, gap, floors, width_limit)
    local result, largest, total = {}, minimum, 0
    for i = 1, count do largest = math.max(largest, natural[i] or 0) end
    for i = 1, count do
        result[i] = homogeneous and largest or math.max(minimum, natural[i] or 0)
        total = total + result[i]
    end
    local available = math.max(0, extent - inset(gap) - gaps(gap,1,math.max(1,count)))
    local shrink_available = math.max(0, (width_limit or extent) - inset(gap) - gaps(gap,1,math.max(1,count)))
    if floors and shrink_available < total then
        if homogeneous then
            local floor = minimum
            for _, value in ipairs(floors) do floor = math.max(floor,value) end
            for i = 1,count do result[i] = math.max(floor,math.floor(shrink_available/count)) end
        else
            local floor_total = 0
            for _, value in ipairs(floors) do floor_total = floor_total + value end
            local fraction = math.max(0,shrink_available-floor_total) / math.max(1,total-floor_total)
            for i = 1,count do result[i] = floors[i] + math.floor((result[i]-floors[i])*fraction) end
        end
    elseif expand and available > total then
        for i = 1, count do
            result[i] = math.floor(total > 0 and available * result[i] / total or available / count)
        end
    end
    return result
end
local function equal(a,b)
    if not a or #a ~= #b then return false end
    for i,v in ipairs(a) do if v ~= b[i] then return false end end
    return true
end
local function prefix(values)
    local sums = {[0]=0}
    for i,v in ipairs(values or {}) do sums[i] = sums[i-1]+v end
    return sums
end
local function extent(sums, first, span, gap)
    return sums[first+span-1]-sums[first-1]+gaps(gap,first,span)
end

-- Inspect only current bindings. Postorder private settlement means descendant helpers
-- have already declared whether this solve reflects their current requirements.
local function sample_content(cell, parent)
    local sample = {width=0,height=0,ready=true,remeasuring=false,flexible=false,dependent=false}
    local function walk(node, rigid)
        for _,binding in clay.bindings(node) do
            if binding.parent == parent and node.box then
                sample.width, sample.height = node.box.width, node.box.height
            end
            if binding ~= parent and binding.grid_state then
                sample.ready = sample.ready and binding.grid_state.settled == true
                sample.remeasuring = sample.remeasuring or binding.grid_state.phase ~= 'allocated'
                sample.dependent = true
                -- A settled inner grid whose rigid floors dominate its
                -- preferences cannot become narrower in an ancestor probe.
                rigid = rigid or binding.grid_state.flexible == false
            end
        end
        if node.text and node.text:find('[ \t]') then
            sample.dependent = true
            sample.flexible = sample.flexible or not rigid
        end
        for _,child in ipairs(node.children or {}) do walk(child,rigid) end
    end
    walk(cell)
    -- Authored width is a real floor even when it contains wrapping text.
    for _,binding in clay.bindings(cell.children and cell.children[1] or {}) do
        if binding.parent == parent and binding.widget._private.forced_width then sample.flexible=false end
    end
    return sample
end

function constructor.describe(widget, fg, compiler, occurrence, offer)
    local p = widget._private
    -- With no tracks or borders there is nothing to measure. An ordinary empty
    -- declaration lets the compiler omit zero-area content while retaining the
    -- occurrence's signals. Forced allocations keep the sizing lifecycle so
    -- content-sized hosts consume their changed dimensions before presentation.
    if p.num_rows == 0 and p.num_cols == 0 and not p.forced_width and not p.forced_height
            and not p.has_border
            and not next(p.custom_border_width.rows) and not next(p.custom_border_width.cols) then
        occurrence.grid_state = nil
        return {}
    end
    -- Authored order decides which occurrence is off-flow. Sparse occupied
    -- ranges include earlier overlays too: an overlay cannot make a later
    -- intersecting occurrence start contributing to the tracks.
    -- Logical membership and overlap order do not change between dependency
    -- solves. Content/membership signals advance the occurrence revision; offers
    -- and solved track sizes never enter this cache.
    local topology = occurrence.grid_topology
    if not topology or topology.revision ~= occurrence.revision then
        local occupied, ranges, overlays, flow = {}, {}, {}, {}
        local function range(t,lo,hi,first,last,mark)
            if t.full then return true end
            if first<=lo and hi<=last then
                if mark then t.full=true;return end
                return t.used
            end
            local mid=math.floor((lo+hi)/2)
            local hit=false
            if first<=mid then
                t.left=t.left or {};hit=range(t.left,lo,mid,first,last,mark) or hit
            end
            if last>mid then
                t.right=t.right or {};hit=range(t.right,mid+1,hi,first,last,mark) or hit
            end
            if mark then t.used=true end
            return hit
        end
        for i,item in ipairs(p.widgets) do
            local overlap=false
            for r=item.row,item.row+item.row_span-1 do
                ranges[r]=ranges[r] or {}
                overlap=range(ranges[r],1,p.num_cols,item.col,item.col+item.col_span-1) or overlap
            end
            overlays[i]=overlap or nil
            if not overlap then flow[i]=true end
            for r=item.row,item.row+item.row_span-1 do
                range(ranges[r],1,p.num_cols,item.col,item.col+item.col_span-1,true)
                if not overlap then
                    occupied[r] = occupied[r] or {}
                    occupied[r][#occupied[r]+1] = {first=item.col,last=item.col+item.col_span-1,index=i,anchor=r==item.row}
                end
            end
        end
        for _,intervals in pairs(occupied) do table.sort(intervals,function(a,b) return a.first<b.first end) end
        topology={revision=occurrence.revision,occupied=occupied,overlays=overlays,flow=flow}
        occurrence.grid_topology=topology
    end
    local occupied,overlays,flow=topology.occupied,topology.overlays,topology.flow
    local xgap = clay.pixels(widget,'horizontal_spacing',p.horizontal_spacing)
    local ygap = clay.pixels(widget,'vertical_spacing',p.vertical_spacing)
    local decorated = p.has_border or next(p.custom_border_width.rows) or next(p.custom_border_width.cols)
    if decorated then
        xgap=borders.axis(widget,'cols',p.num_cols,xgap)
        ygap=borders.axis(widget,'rows',p.num_rows,ygap)
    end
    local xmin = clay.pixels(widget,'min_cols_size',p.min_cols_size)
    local ymin = clay.pixels(widget,'min_rows_size',p.min_rows_size)
    compiler.observe_layout(occurrence)
    local state = occurrence.grid_state
    if not state or state.revision ~= occurrence.revision or state.context ~= compiler.context
            or state.layout_revision ~= compiler.cache.layout_revision then
        state = {revision=occurrence.revision,context=compiler.context,
            layout_revision=compiler.cache.layout_revision,solves=0,updates=0,phase='natural'}
        occurrence.grid_state = state
    end
    local scope = occurrence.grid_measurement or 0
    if state.dependent and state.offer_width ~= offer.w and scope == 0 and state.scope == 0 then
        -- A new host width changes the available preferred sample for wrapping.
        -- Ancestor probe offers are phase inputs, not new authored content.
        state.phase = 'natural'
    end
    compiler.offer_dependent = true
    state.offer_width, state.scope = offer.w, scope
    local minimum = state.phase == 'minimum'
    local natural = state.phase == 'natural'
    local measuring_height = state.phase ~= 'allocated'
    local columns, heights = prefix(state.columns), prefix(state.rows)
    local samples, rows, areas = {}, {}, {}
    local function area_key(r,c,rs,cs) return table.concat({r,c,rs,cs},':') end
    local inner,outer
    if decorated and p.num_rows>0 and p.num_cols>0 then inner,outer=borders.solid_colors(p,fg) end
    local compact = inner ~= nil
    local paint = decorated and not measuring_height and not compact and borders.painter(p,fg,xgap,ygap,state.columns,state.rows,flow)
    local function gap_node(c,r,xb,yb)
        if paint then return paint(c,r,xb,yb) end
        return {w=xb and xgap[c].size or 'grow',h=yb and ygap[r].size or 'grow'}
    end
    local function row_gap(r)
        local cells={}
        for c=1,p.num_cols do
            cells[#cells+1]=gap_node(c,r,true,true)
            cells[#cells+1]=gap_node(c,r,false,true)
        end
        cells[#cells+1]=gap_node(p.num_cols+1,r,true,true)
        rows[#rows+1]={dir='x',w='fit',h=ygap[r].size,children=cells}
    end
    for r=1,p.num_rows do
        local cells = {}
        if decorated and not compact then row_gap(r) end
        local row_height = not measuring_height and state.rows[r]
        if compact and row_height then
            row_height=row_height+ygap[r].width+ygap[r].after+ygap[r+1].before
                +(r==p.num_rows and ygap[r+1].width or 0)
        end
        rows[#rows+1] = {dir='x',gap=not decorated and xgap or nil,w='fit',h=row_height or 'fit',children=cells}
        local c=1
        local function cell(first,span,index,anchor)
            local item = index and p.widgets[index]
            local height_span = anchor and item.row_span or 1
            -- Zero maximum means unbounded to Clay; a positive probe exposes
            -- native content minima through this same original occurrence.
            local node = {w=minimum and 1 or natural and 'fit' or extent(columns,first,span,xgap),
                h=measuring_height and 'fit' or extent(heights,r,height_span,ygap),
                wmin=natural and (span*xmin+gaps(xgap,first,span)) or nil,
                hmin=measuring_height and ymin or nil,
                children=anchor and {{widget=item.widget,w=(natural or minimum) and 'fit' or 'grow',
                    h=measuring_height and 'fit' or 'grow'}} or {},
                _settle=function(n) if anchor then samples[index] = sample_content(n,occurrence) end end}
            if compact then
                local last_col=first+span
                local last_row=r+(measuring_height and 1 or height_span)
                local right=last_col==p.num_cols+1 and xgap[last_col].width or 0
                local bottom=last_row==p.num_rows+1 and ygap[last_row].width or 0
                local pad={xgap[first].width+xgap[first].after,xgap[last_col].before+right,
                    ygap[r].width+ygap[r].after,ygap[last_row].before+bottom}
                if type(node.w)=='number' then node.w=node.w+pad[1]+pad[2] end
                if type(node.h)=='number' then node.h=node.h+pad[3]+pad[4] end
                if node.wmin then node.wmin=node.wmin+pad[1]+pad[2] end
                if node.hmin then node.hmin=node.hmin+pad[3]+pad[4] end
                node.pad=pad
                -- A spanning cell owns its whole border envelope. Continuation
                -- slots reserve row space without repainting that envelope.
                if inner==outer then
                    if not measuring_height and (not item or anchor) then
                        local color={inner[1],inner[2],inner[3],inner[4]}
                        if not item or item.widget._private.visible==false then node.bg=color
                        else node.border=color;node.bw={xgap[first].width,right,ygap[r].width,bottom} end
                    end
                elseif not item or anchor then
                    local hole=not item or item.widget._private.visible==false
                    local edges={xgap[first].width,right,ygap[r].width,bottom}
                    local outside={first==1 and edges[1] or 0,right,r==1 and edges[3] or 0,bottom}
                    local inside={first>1 and edges[1] or 0,0,r>1 and edges[3] or 0,0}
                    local has_outer=outside[1]+outside[2]+outside[3]+outside[4]>0
                    local has_inner=inside[1]+inside[3]>0
                    local color=inner
                    local envelope=node
                    if inner~=outer and has_outer then
                        color=outer
                        if hole or has_inner then
                            -- Keep both colors in this cell's paint order. The
                            -- outer stroke consumes padding, so the inner fill
                            -- and strokes never blend underneath it.
                            envelope={w=node.w,h=node.h,wmin=node.wmin,hmin=node.hmin,
                                pad=outside,children={node}}
                            if type(node.w)=='number' then node.w='grow' end
                            if type(node.h)=='number' then node.h='grow' end
                            if node.wmin then node.wmin=node.wmin-outside[1]-outside[2] end
                            if node.hmin then node.hmin=node.hmin-outside[3]-outside[4] end
                            for side=1,4 do pad[side]=pad[side]-outside[side] end
                            if not measuring_height then
                                envelope.border={outer[1],outer[2],outer[3],outer[4]};envelope.bw=outside
                            end
                            color=inner;edges=inside
                        end
                    end
                    if not measuring_height then
                        local rgba={color[1],color[2],color[3],color[4]}
                        if hole then node.bg=rgba else node.border=rgba;node.bw=edges end
                    end
                    node=envelope
                end
            elseif decorated then
                cells[#cells+1]=gap_node(first,r,true,false)
                if paint and (not item or item.widget._private.visible == false) then
                    for col=first,first+span-1 do
                        if col>first then node.children[#node.children+1]=paint(col,r,true,false) end
                        node.children[#node.children+1]=paint(col,r,false,false)
                    end
                end
            end
            cells[#cells+1] = node
            if not compact then areas[area_key(r,first,height_span,span)]=node end
        end
        for _,interval in ipairs(occupied[r] or {}) do
            while c < interval.first do cell(c,1);c=c+1 end
            cell(c,interval.last-c+1,interval.index,interval.anchor)
            c=interval.last+1
        end
        while c<=p.num_cols do cell(c,1);c=c+1 end
        if decorated and not compact then cells[#cells+1]=gap_node(p.num_cols+1,r,true,false) end
    end
    if decorated and not compact then row_gap(p.num_rows+1) end
    local node = {specs={{dir='y',gap=not decorated and ygap or nil,w='fit',h='fit',children=rows}}}
    for i,item in ipairs(p.widgets) do
        if overlays[i] then
            local key=area_key(item.row,item.col,item.row_span,item.col_span)
            local anchor=areas[key]
            if not anchor then
                -- A real span area, positioned by ordinary row/column spacers.
                -- The whole scaffold floats, so neither it nor its content can
                -- enlarge a track. Probe phases use zero sizing inputs; the
                -- allocated declarations use the same shared tracks as cells.
                local function size(sums,first,span,gap)
                    return measuring_height and 0 or extent(sums,first,span,gap)
                end
                local function before(sums,first,gap)
                    return measuring_height and 0 or sums[first-1]+gaps(gap,1,first)
                        +(decorated and gap[1].size or 0)
                end
                anchor={name='grid.span-area',w=size(columns,item.col,item.col_span,xgap),
                    h=size(heights,item.row,item.row_span,ygap)}
                rows[#rows+1]={float=true,passthrough=true,dir='y',w='fit',h='fit',children={
                    {w=0,h=before(heights,item.row,ygap)},
                    {dir='x',w='fit',h='fit',children={
                        {w=before(columns,item.col,xgap),h=0},anchor}}}}
                areas[key]=anchor
            end
            -- Append in authored order, independently of row-major cell order.
            -- _attach is a current-tree reference, resolved by the bridge to
            -- Clay's existing element attachment, never a stored rectangle.
            node.specs[#node.specs+1]={widget=item.widget,float=true,_attach=anchor,w='fit',h='fit'}
        end
    end
    node._settle = function(solved)
        if occurrence.grid_state ~= state or occurrence.revision ~= state.revision
                or compiler.cache.layout_revision ~= state.layout_revision then return end
        state.solves = state.solves+1
        state.settled = false
        for _,sample in pairs(samples) do
            if not sample.ready then
                -- Never retain an allocated inner grid's old height when it is
                -- remeasuring after a width/measurement-scope change. Pure
                -- expansion stays allocated; resampling it would alternate
                -- suppression and expansion forever in a flex-height year.
                if state.phase == 'allocated' and sample.remeasuring then
                    state.phase = 'height'
                    state.updates = state.updates + 1
                    compiler.update_declarations(occurrence)
                end
                return
            end
        end
        local box = assert(solved.box,'grid occurrence has no current solved box')
        if natural then
            state.natural_columns = requirements(p.widgets,samples,'width',p.num_cols,xmin,xgap)
            state.floors = requirements(p.widgets,samples,'width',p.num_cols,xmin,xgap,true)
            state.dependent, state.flexible = false,false
            for _,sample in pairs(samples) do
                state.dependent = state.dependent or sample.dependent
                state.flexible = state.flexible or sample.flexible
            end
        end
        -- A minimum-width probe cannot add information when rigid content
        -- already supplies every natural column requirement. Calendar weekday
        -- labels, for example, dominate the padded single-digit day labels.
        -- Keep height dependency tracking: wider allocation can still unwrap.
        if natural and equal(state.floors,state.natural_columns) then
            state.flexible = false
        end
        if minimum then
            state.floors = requirements(p.widgets,samples,'width',p.num_cols,xmin,xgap)
        end
        if measuring_height and not minimum then
            state.natural_rows = requirements(p.widgets,samples,'height',p.num_rows,ymin,ygap)
        end
        -- A probe's tiny real box is not the host's available width. FIT
        -- content may grow to its shared preference; only its compiler offer
        -- (or an authored width) bounds it. Allocated grids also honor Clay's
        -- current box, which accounts for sibling competition.
        if not minimum then
            state.expand_width = math.min(p.forced_width or offer.w,box.width)
            state.width_extent = math.min(p.forced_width or offer.w,
                occurrence.grid_fit_width and offer.w or box.width)
        end
        local next_columns = tracks(state.natural_columns,p.num_cols,xmin,p.horizontal_homogeneous,
            (scope==0 or scope==2) and p.horizontal_expand,state.expand_width,xgap,
            state.flexible and state.floors or nil,state.width_extent)
        local next_rows = tracks(state.natural_rows,p.num_rows,ymin,p.vertical_homogeneous,
            scope==0 and p.vertical_expand,math.min(p.forced_height or offer.h,box.height),ygap)
        if scope == 4 then
            next_columns = tracks(state.floors,p.num_cols,xmin,p.horizontal_homogeneous,false,0,xgap)
        end
        local width_changed = not equal(state.columns,next_columns)
        local next_phase = 'allocated'
        -- Natural readback already measured height at the required width
        -- when every width-dependent occurrence has exactly its new offer.
        -- Compare real occurrence sizes, never infer text metrics in Lua.
        local measured_widths = natural
        if measured_widths and state.dependent then
            local sums = prefix(next_columns)
            for i,sample in pairs(samples) do
                local item = p.widgets[i]
                if sample.dependent and sample.width ~= extent(sums,item.col,item.col_span,xgap) then
                    measured_widths = false
                    break
                end
            end
        end
        if state.dependent and (width_changed or minimum) and not measured_widths then next_phase = 'height' end
        if natural and state.flexible then next_phase = 'minimum' end
        local changed = width_changed or not equal(state.rows,next_rows) or next_phase ~= state.phase
        state.columns,state.rows,state.phase = next_columns,next_rows,next_phase
        if changed then
            state.updates=state.updates+1
            compiler.update_declarations(occurrence)
        else state.settled=true end
    end
    return node
end
return constructor
