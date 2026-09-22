local runner=require('_runner')
local awful=require('awful')
local utils=require('_utils')
local golden=require('_clay_example')
local a,b,before
runner.run_steps({
 function()
  local t=screen[1].selected_tag
  t.layout=awful.layout.suit.tile;t.master_width_factor=0.5;t.gap=8
  awful.spawn{'./build-test/test-transient-client','resize_a'}
  awful.spawn{'./build-test/test-transient-client','resize_b'}
  return true
 end,
 function(n)
  a=utils.find_client_by_class('resize_a');b=utils.find_client_by_class('resize_b')
  if not a or not b then assert(n<30,'no clients');return end
  a.floating=false;b.floating=false;a.shadow=false;b.shadow=false
  a.border_width=1;b.border_width=1
  if awful.client.tiled(screen[1])[1]~=a then a:swap(b) end
  return true
 end,
 function(n)
  if n<3 then return end
  golden.check("resizable-splits-before",awesome._clay_tree(screen[1]))
  before=golden.shape(awesome._clay_tree(screen[1]))
  awful.layout.suit.tile.mouse_resize_handler(a)
  awful.spawn{'./build-test/test-virtual-pointer-client','click','762','360','1280','720','left'}
  return true
 end,
 function(n)
  local factor=screen[1].selected_tag.master_width_factor
  if mousegrabber.isrunning() or math.abs(factor-0.5)<0.01 then
   assert(n<30,'pointer did not update master_width_factor');return
  end
  assert(math.abs(factor-(762-8)/1256)<0.001,'wrong pointer-derived share')
  local after=golden.shape(awesome._clay_tree(screen[1]))
  assert(after:gsub('percent%([%d.]+%)','percent(SPLIT)')==before:gsub('percent%([%d.]+%)','percent(SPLIT)'),
   'mouse resize changed declarations other than percent')
  assert(after~=before,'next frame did not declare new percent')
  golden.check('resizable-splits-after',awesome._clay_tree(screen[1]))
  io.stderr:write('[PASS] virtual pointer writes master_width_factor='..factor..'; only percent changes\n')
  return true
 end,
 function()a:kill();b:kill();return true end,
},{kill_clients=false})
