local runner=require('_runner')
local awful=require('awful')
local utils=require('_utils')
local binary=assert(utils.binary_or_skip('./build-test/test-transient-client'))
local report=os.tmpname()
local a,b
local function box(role,c)
 for line in awesome._clay_tree(screen[1]):gmatch('[^\n]+') do
  if line:match('^%s*'..role..' '..c.class..' ') then
   local x,y,w,h=line:match('box (%d+),(%d+) (%d+)x(%d+)')
   return tonumber(x),tonumber(w),line
  end
 end
 error('no '..role)
end
runner.run_steps({
 function()
  local t=screen[1].selected_tag
  t.layout=awful.layout.suit.tile; t.master_width_factor=0.5; t.gap=8
  awful.spawn{binary,'hint_master',report,'800'}
  awful.spawn{binary,'hint_stack'}
  return true
 end,
 function(n)
  a=utils.find_client_by_class('hint_master');b=utils.find_client_by_class('hint_stack')
  if not a or not b then assert(n<30,'no clients');return end
  for _,c in ipairs{a,b} do
   c.floating=false;c.border_width=1;c.shadow=false;c.size_hints_honor=true
   awful.titlebar(c,{size=24})
  end
  if awful.client.tiled(screen[1])[1]~=a then a:swap(b) end
  return true
 end,
 function(n)
  local ok,err=pcall(function()
   local x,w,slot=box('CLIENT',a)
   local sx,sw,leaf=box('SURFACE',a)
   assert(w==628 and slot:find('percent(0.5)',1,true),'master percent not authoritative')
   assert(sw==800 and sx==x+1,'surface does not honor minimum')
   assert(sx+sw-(x+w-1)==174,'minimum overhang must be exactly 800-626=174')
   assert(leaf:find('protocol',1,true),'missing hint provenance')
   local f=assert(io.open(report));local received=f:read('*a');f:close()
   assert(received:match('^800 '),'configure clamped below surface minimum')
   io.stderr:write('[PASS] slot=628 inner=626 surface=800 overhang=174; client received '..received)
  end)
  if ok then return true end
  assert(n<30,err)
 end,
 function() a:kill();b:kill();os.remove(report);return true end,
},{kill_clients=false})
