local runner=require('_runner')
local awful=require('awful')
local utils=require('_utils')
local capture=require('_widget_capture')
local surface=require('gears.surface')
local p,c,pid
local function shown(obj)
 for _,v in ipairs(awesome._test_declare_order(screen[1])) do if v==obj then return true end end
end
runner.run_steps({
 function(n)
  if n==1 then
   screen[1].selected_tag.layout=awful.layout.suit.tile
   pid=awful.spawn('./build-test/test-transient-client')
  end
  p=utils.find_client_by_class('transient_test_parent')
  if p then p.floating=false;p.shadow=false;return true end
  assert(n<30,'parent did not map')
 end,
 function(n)
  if n<3 then return end
  awful.spawn('kill -USR1 '..pid);return true
 end,
 function(n)
  c=utils.find_client_by_class('transient_test_child')
  if not c then assert(n<30,'child did not map');return end
  c.floating=true;c.shadow=false;c:geometry{x=100,y=100,width=200,height=160}
  return true
 end,
 function(n)
  if not shown(c) then assert(n<20,'floating transient of tiled parent is absent');return end
  local r,g,b=capture.read(surface(root.content()),150,150)
  assert(r==128 and g==64 and b==64,'transient not painted above tiled parent')
  return true
 end,
 function()p.floating=true;c.floating=false;return true end,
 function(n)
  if n<3 then return end
  assert(shown(p) and shown(c),'each client must be declared exactly once')
  io.stderr:write('[PASS] floating transient of tiled parent and tiled transient of floating parent\n')
  return true
 end,
 function()p:kill();return true end,
},{kill_clients=false})
