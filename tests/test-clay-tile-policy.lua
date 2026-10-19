local runner=require('_runner')
local awful=require('awful')
local utils=require('_utils')
local c
runner.run_steps({
 function(n)
  if n==1 then
   local t=screen[1].selected_tag
   t.layout=awful.layout.suit.tile;t.gap=0;t.master_width_factor=0.4;t.master_fill_policy='master_width_factor'
   awful.spawn('./build-test/test-transient-client')
  end
  c=utils.find_client_by_class('transient_test_parent')
  if not c then assert(n<30,'client did not map');return end
  c.floating=false;c.shadow=false;c.border_width=1;c.size_hints_honor=false
  return true
 end,
 function(n)
  local g=c:geometry()
  if g.x~=384 or g.width+2*c.border_width~=512 then assert(n<20,'master_fill_policy must center the percent run');return end
  io.stderr:write('[PASS] master_fill_policy centers a percent run\n')
  return true
 end,
 function()c:kill();return true end,
},{kill_clients=false})
