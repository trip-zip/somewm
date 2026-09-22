local grid = require('wibox.layout.grid')
local base = require('wibox.widget.base')
local clay = require('wibox.clay')
local constructor = require('wibox.layout._grid_constructor')
local solver = dofile('tests/clay/grid-helper.lua')
local function leaf(w,h)
    local widget = base.make_widget()
    widget._private.natural = {w=w,h=h}
    widget._clay = {describe=function(self)
        return {w=self._private.natural.w,h=self._private.natural.h,bg={1,0,0,1}}
    end}
    return widget
end
local function prepared(args)
    local g = grid()
    g.column_count=2; g.spacing=5
    for k,v in pairs(args or {}) do g[k]=v end
    return g
end
local serial = 0
local function host(g,width,height,fit)
    local self = {_attachment_fit=fit, context={dpi=96}, requests=0,
        width=width or 400,height=height or 200}
    self._clay_compile=function() self.requests=self.requests+1 end
    function self:frame()
        serial=serial+1
        local tree = clay.compile(self,g,self.context,self.width,self.height)
        clay._publish(self,tree,solver.solve(tree,'helper-'..serial))
        return tree
    end
    function self:settle(bound)
        local frames=0
        repeat
            local before=self.requests
            self:frame(); frames=frames+1
            assert(frames<=(bound or 3),'grid did not settle') -- assertion, never a production cap
            if before==self.requests then break end
        until false
        return frames
    end
    function self:change(w, width_, height_)
        if width_ then w._private.natural={w=width_,h=height_ or w._private.natural.h} end
        clay.invalidate(self,w)
        return self:settle()
    end
    return self
end
local function box(self,w,expected)
    local found=solver.find(self._clay_tree,w)
    assert.equals(1,#found)
    local b=found[1].box
    assert.same(expected,{b.x,b.y,b.width,b.height})
    return found[1].binding
end

describe('grid helper lifecycle through pristine Clay',function()
    setup(solver.start)
    teardown(solver.stop)
    it('uses shared sizing for public grids',function()
        assert.equals(grid._clay.describe,constructor.describe)
    end)
    it('equalizes 40/70, releases either maximum, hides/removes/restores and stops updating',function()
        local g=prepared(); local a,b=leaf(40,10),leaf(70,10); g:add(a,b)
        local d=host(g,400,200,true)
        d:frame(); box(d,g,{0,0,115,10}); box(d,a,{0,0,40,10})
        assert.equals(1,d.requests)
        d:frame(); box(d,g,{0,0,145,10}); local aid=box(d,a,{0,0,70,10}).id
        local bid=box(d,b,{75,0,70,10}).id
        assert.equals(1,d.requests)
        for _,change in ipairs{{a,100,10,205},{a,40,10,145},{b,120,30,245},{b,70,10,145}} do
            assert.equals(2,d:change(change[1],change[2],change[3]))
            box(d,g,{0,0,change[4],change[3]})
            assert.equals(aid,solver.find(d._clay_tree,a)[1].binding.id)
            assert.equals(bid,solver.find(d._clay_tree,b)[1].binding.id)
        end
        b:set_visible(false); assert.equals(2,d:change(b)); box(d,g,{0,0,85,10})
        assert.equals(0,#solver.find(d._clay_tree,b))
        b:set_visible(true); assert.equals(2,d:change(b)); box(d,g,{0,0,145,10})
        assert.equals(bid,solver.find(d._clay_tree,b)[1].binding.id)
        g:remove(b); assert.equals(2,d:change(g)); box(d,g,{0,0,85,10})
        g:add_widget_at(b,1,2); assert.equals(2,d:change(g)); box(d,g,{0,0,145,10})
        local requests=d.requests
        for _=1,5 do d:frame() end
        assert.equals(requests,d.requests)
    end)
    it('shares both intrinsic axes and expands in content proportions independently',function()
        for _,policy in ipairs{
            {homogeneous=false,extent={115,55},areas={{0,0,40,20},{45,0,70,20},{0,25,40,30},{45,25,70,30}}},
            {homogeneous=true,extent={145,65},areas={{0,0,70,30},{75,0,70,30},{0,35,70,30},{75,35,70,30}}},
            {homogeneous=false,expand={horizontal=true,vertical=false},forced_width=225,forced_height=80,
                extent={225,80},areas={{0,0,80,20},{85,0,140,20},{0,25,80,30},{85,25,140,30}}},
            {homogeneous={horizontal=false,vertical=true},expand={horizontal=false,vertical=true},
                forced_width=200,forced_height=125,extent={200,125},
                areas={{0,0,40,60},{45,0,70,60},{0,65,40,60},{45,65,70,60}}},
            {homogeneous={horizontal=true,vertical=false},expand={horizontal=false,vertical=true},
                forced_height=105,extent={145,105},
                areas={{0,0,70,40},{75,0,70,40},{0,45,70,60},{75,45,70,60}}},
        } do
            local g=prepared{homogeneous=policy.homogeneous,expand=policy.expand or false,
                forced_width=policy.forced_width,forced_height=policy.forced_height}
            local ws={leaf(40,10),leaf(70,20),leaf(20,30),leaf(30,10)};g:add(table.unpack(ws))
            local d=host(g,400,200,true);assert.equals(2,d:settle())
            box(d,g,{0,0,policy.extent[1],policy.extent[2]})
            for i,w in ipairs(ws) do box(d,w,policy.areas[i]) end
        end
    end)
    it('preserves floor/remainder on resize and intrinsic floors under shortage',function()
        local g=prepared{expand=true};local a,b=leaf(40,10),leaf(70,10);g:add(a,b)
        local d=host(g,200,80);assert.equals(2,d:settle())
        box(d,a,{0,0,97,80});box(d,b,{102,0,97,80})
        d.width=201;assert.equals(2,d:settle());box(d,b,{103,0,98,80})
        d.width=25;assert.equals(2,d:settle());box(d,a,{0,0,70,80});box(d,b,{75,0,70,80})
    end)
    it('preserves 0/1/2/7 occupancy, explicit holes, zero minima and repeated occurrences',function()
        for _,n in ipairs{0,1,2,7} do
            local g=prepared{column_count=3,expand={horizontal=true,vertical=false},minimum_row_height=20}
            local ws={};for i=1,n do ws[i]=leaf(10,20);g:add(ws[i]) end
            local d=host(g,300,200);assert.equals(2,d:settle())
            for i,w in ipairs(ws) do box(d,w,{((i-1)%3)*101,math.floor((i-1)/3)*25,96,20}) end
        end
        local g=prepared{column_count=3,homogeneous=false};local a=leaf(40,10)
        g:add_widget_at(a,1,1);g:add_widget_at(a,2,3)
        local d=host(g,400,200,true);d:settle()
        local found=solver.find(d._clay_tree,a);assert.equals(2,#found)
        assert.is_not_equal(found[1].binding.id,found[2].binding.id)
        assert.same({0,0,40,10}, {found[1].box.x,found[1].box.y,found[1].box.width,found[1].box.height})
        assert.same({50,15,40,10}, {found[2].box.x,found[2].box.y,found[2].box.width,found[2].box.height})
    end)
    it('retains empty authored floors and shares intrinsic minima on both axes',function()
        for _,occupied in ipairs{false,true} do
            local g=prepared{column_count=3,row_count=2,expand=true,minimum_column_width=10,minimum_row_height=20}
            local a=leaf(70,50);if occupied then g:add(a) end
            local d=host(g,25,25);d:settle()
            if occupied then box(d,a,{0,0,70,50}) end
            local state=solver.find(d._clay_tree,g)[1].binding.grid_state
            assert.same(occupied and {70,70,70} or {10,10,10},state.columns)
            assert.same(occupied and {50,50} or {20,20},state.rows)
        end
    end)
    it('keeps state separate for two occurrences of one grid',function()
        local g=prepared{expand=true};g:add(leaf(40,10),leaf(70,10))
        local root=base.make_widget();root._clay={describe=function()
            return {dir='y',specs={{widget=g,w=200,h=40},{widget=g,w=300,h=50}}}
        end}
        local d=host(root,400,200);assert.equals(2,d:settle())
        local found=solver.find(d._clay_tree,g);assert.equals(2,#found)
        assert.same({97,97},found[1].binding.grid_state.columns)
        assert.same({147,147},found[2].binding.grid_state.columns)
        assert.equals(2,d.requests)
        d:frame();assert.equals(2,d.requests)
    end)
    it('uses the native allocation when siblings share the compiler offer',function()
        local g=prepared{expand=true};g:add(leaf(40,10),leaf(70,10))
        local sidebar=leaf(100,20)
        local root=base.make_widget();root._clay={describe=function()
            return {dir='x',specs={{widget=sidebar},{widget=g,w='grow',h='grow'}}}
        end}
        local d=host(root,400,80);assert.equals(2,d:settle())
        local state=solver.find(d._clay_tree,g)[1].binding.grid_state
        assert.same({147,147},state.columns)
        assert.equals(2,d:change(sidebar,200))
        state=solver.find(d._clay_tree,g)[1].binding.grid_state
        assert.same({97,97},state.columns)
        assert.equals(2,d:change(sidebar,100))
        state=solver.find(d._clay_tree,g)[1].binding.grid_state
        assert.same({147,147},state.columns)
    end)
    it('publishes current bindings/index before callbacks, even when one fails',function()
        local gdebug=require('gears.debug');local original=gdebug.print_error;local errors=0
        gdebug.print_error=function() errors=errors+1 end
        local self={_clay_tree={},_clay_index={}}
        local binding={};local child={bindings={item=binding},solved=function() error('expected callback failure') end}
        local tree={children={child},solved=function(n)
            assert.equals(n,self._clay_tree);assert.equals(child,self._clay_index[2])
            assert.equals(child,binding.element)
        end}
        clay._publish(self,tree,{{width=10},{width=5}})
        gdebug.print_error=original
        assert.equals(1,errors);assert.equals(tree,self._clay_tree)
    end)
    it('matches the unchanged accepted column and row span rectangles',function()
        for _,case in ipairs{
            {args={column_count=3,forced_width=300,
                homogeneous={horizontal=true,vertical=false},expand={horizontal=true,vertical=false}},
                items={{100,10,1,1,1,3},{70,20,2,1,1,2},{30,20,2,3},{20,10,3,1},{80,10,3,2,1,2}},
                extent={300,50},areas={{0,0,298,10},{0,15,197,20},{202,15,96,20},{0,40,96,10},{101,40,197,10}}},
            {args={homogeneous=false},
                items={{40,55,1,1,2,1},{70,20,1,2},{30,30,2,2},{100,10,3,1,1,2}},
                extent={123,75},areas={{0,0,48,60},{53,0,70,25},{53,30,70,30},{0,65,123,10}}},
        } do
            local g=prepared(case.args);local ws={}
            for _,i in ipairs(case.items) do
                local w=leaf(i[1],i[2]);ws[#ws+1]=w
                g:add_widget_at(w,i[3],i[4],i[5],i[6])
            end
            local d=host(g,400,200,true);d:settle(12)
            box(d,g,{0,0,case.extent[1],case.extent[2]})
            for i,w in ipairs(ws) do box(d,w,case.areas[i]) end
            local before=d.requests;d:frame();assert.equals(before,d.requests)
        end
    end)
    it('waits for nested shared requirements and releases their old heights',function()
        local inner=prepared();local a,b=leaf(40,10),leaf(70,30);inner:add(a,b)
        local outer=prepared{homogeneous=false};local c=leaf(20,5);outer:add(inner,c)
        local d=host(outer,400,200,true);d:settle(12)
        box(d,outer,{0,0,170,30});box(d,inner,{0,0,145,30})
        a._private.natural={w=100,h=60};clay.invalidate(d,a);d:settle(12)
        box(d,outer,{0,0,230,60})
        a._private.natural={w=40,h=10};clay.invalidate(d,a);d:settle(12)
        box(d,outer,{0,0,170,30})
        local before=d.requests;for _=1,5 do d:frame() end
        assert.equals(before,d.requests)
    end)
    it('reverses span requirements and retains duplicate occurrence holes',function()
        local g=prepared{column_count=3,homogeneous=false}
        local a,b=leaf(100,55),leaf(20,10)
        g:add_widget_at(a,1,1,2,2);g:add_widget_at(b,1,3);g:add_widget_at(b,3,2)
        local d=host(g,400,200,true);d:settle(12)
        box(d,a,{0,0,101,55})
        local repeated=solver.find(d._clay_tree,b)
        assert.equals(2,#repeated);assert.is_not_equal(repeated[1].binding.id,repeated[2].binding.id)
        local first=solver.find(d._clay_tree,a)[1].binding.id
        a._private.natural={w=180,h=95};clay.invalidate(d,a);d:settle(12)
        box(d,a,{0,0,181,95})
        a._private.natural={w=100,h=55};clay.invalidate(d,a);d:settle(12)
        box(d,a,{0,0,101,55});assert.equals(first,solver.find(d._clay_tree,a)[1].binding.id)
        a:set_visible(false);clay.invalidate(d,a);d:settle(12)
        assert.equals(0,#solver.find(d._clay_tree,a));box(d,g,{0,0,50,30})
        a:set_visible(true);clay.invalidate(d,a);d:settle(12);box(d,a,{0,0,101,55})
        g:remove(a);clay.invalidate(d,g);d:settle(12);box(d,g,{0,0,50,30})
        g:add_widget_at(a,1,1,2,2);clay.invalidate(d,g);d:settle(12);box(d,a,{0,0,101,55})
    end)
    it('does not mistake nested expansion for a new natural height dependency',function()
        local inner=prepared{expand=true};inner:add(leaf(40,10),leaf(70,10))
        local outer=prepared{column_count=1,expand=true};outer:add(inner)
        local d=host(outer,300,100);d:settle(12)
        box(d,inner,{0,0,300,100})
        local requests=d.requests
        for _=1,10 do d:frame() end
        assert.equals(requests,d.requests)
        d.height=50;d:settle(12);box(d,inner,{0,0,300,50})
    end)
    it('preserves accepted standard/custom/span border geometry with ordinary declarations',function()
        for _,custom in ipairs{false,true} do
            local g=prepared{border_width={inner=1,outer=custom and 2 or 1},border_color='#ffffff'}
            local ws={leaf(20,20),leaf(20,20),leaf(20,20),leaf(20,20)}
            g:add(table.unpack(ws))
            if custom then g:add_column_border(2,3,{color='#00ffff',dashes={4,2},dash_offset=1,caps='round'}) end
            local d=host(g,400,200,true);assert.equals(2,d:settle())
            box(d,g,{0,0,custom and 67 or 63,custom and 65 or 63})
            local pad=custom and 7 or 6
            box(d,ws[1],{pad,pad,20,20})
            box(d,ws[4],{custom and 40 or 37,custom and 38 or 37,20,20})
        end
        local g=prepared{border_width=1,border_color='#ffffff',minimum_column_width=20,minimum_row_height=20}
        local a,b=leaf(20,20),leaf(20,20)
        g:add_widget_at(a,1,1,1,2);g:add_widget_at(b,2,1)
        local d=host(g,400,200,true);assert.equals(2,d:settle())
        box(d,g,{0,0,63,63});box(d,a,{6,6,51,20});box(d,b,{6,37,20,20})
        assert.equals(2,d:change(b,40,30));box(d,g,{0,0,103,83})
        assert.equals(2,d:change(b,20,20));box(d,g,{0,0,63,63})
    end)
    it('excludes overlays from sizing and reuses exact cells in pristine Clay',function()
        local g=prepared{superpose=true,homogeneous=false}
        local a,b,o=leaf(40,20),leaf(70,20),leaf(200,60)
        g:add(a,b);g:add_widget_at(o,1,2)
        local d=host(g,400,200,true);assert.equals(2,d:settle())
        box(d,g,{0,0,115,20});box(d,o,{45,0,200,60})
        local on=solver.find(d._clay_tree,o)[1].node
        assert.is_true(on.float);assert.is_not_nil(on._attach.solved)
        assert.equals(2,d:change(o,500,100));box(d,g,{0,0,115,20})
        o:set_visible(false);d:change(o);box(d,g,{0,0,115,20})
        o:set_visible(true);d:change(o);box(d,o,{45,0,500,100})
        g:remove(o);d:change(g);box(d,g,{0,0,115,20})
    end)
    it('builds shared real span anchors without changing tracks or border occupancy',function()
        local g=prepared{superpose=true,homogeneous=false,row_count=2,minimum_row_height=20,border_width=1}
        local a,b,o=leaf(40,20),leaf(70,20),leaf(200,60)
        g:add(a,b);g:add_widget_at(o,1,1,2,2);g:add_widget_at(o,1,1,2,2)
        local d=host(g,400,200,true);assert.equals(2,d:settle())
        box(d,g,{0,0,133,63})
        local repeated=solver.find(d._clay_tree,o)
        assert.equals(2,#repeated);assert.is_not_equal(repeated[1].binding.id,repeated[2].binding.id)
        assert.equals(repeated[1].node._attach,repeated[2].node._attach)
        assert.equals('grid.span-area',repeated[1].node._attach.class)
        assert.same({6,6,200,60},{repeated[1].box.x,repeated[1].box.y,repeated[1].box.width,repeated[1].box.height})
        local requests=d.requests;for _=1,5 do d:frame() end;assert.equals(requests,d.requests)
    end)
    it('anchors inside an existing span and excludes an overlap chain into holes',function()
        local g=prepared{column_count=3,row_count=3,superpose=true,homogeneous=false,
            minimum_column_width=10,minimum_row_height=10}
        local a,b,o,last=leaf(100,55),leaf(30,10),leaf(200,60),leaf(500,100)
        g:add_widget_at(a,1,1,2,2);g:add_widget_at(b,1,3)
        g:add_widget_at(o,2,2,2,2);g:add_widget_at(last,3,3)
        local d=host(g,600,200,true);assert.equals(2,d:settle())
        box(d,g,{0,0,136,70});box(d,o,{53,30,200,60});box(d,last,{106,60,500,100})
        local anchor=solver.find(d._clay_tree,o)[1].node._attach
        assert.equals('grid.span-area',anchor.class);assert.equals(83,anchor.w);assert.equals(40,anchor.h)
        assert.is_not_nil(solver.find(d._clay_tree,last)[1].node._attach.solved)
        a:set_visible(false);d:change(a);box(d,g,{0,0,60,40})
        a:set_visible(true);d:change(a);box(d,g,{0,0,136,70})
        box(d,o,{53,30,200,60})
    end)
end)
