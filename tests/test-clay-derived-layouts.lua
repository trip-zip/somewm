local runner=require('_runner')
local awful=require('awful')
local utils=require('_utils')
local s=screen[1]
local a,b
local steps={
 function()
  awful.spawn{'./build-test/test-transient-client','derived_a'}
  awful.spawn{'./build-test/test-transient-client','derived_b'}
  return true
 end,
 function(n)
  a=utils.find_client_by_class('derived_a');b=utils.find_client_by_class('derived_b')
  if not a or not b then assert(n<30,'no clients');return end
  a.floating=false;b.floating=false;a.shadow=false;b.shadow=false
  return true
 end,
}
for _,native in ipairs {awful.layout.suit.carousel, awful.layout.suit.carousel.vertical,
 awful.layout.suit.tile, awful.layout.suit.spiral, awful.layout.suit.spiral.dwindle,
 awful.layout.suit.max, awful.layout.suit.max.fullscreen, awful.layout.suit.magnifier,
 awful.layout.suit.fair, awful.layout.suit.fair.horizontal,
 awful.layout.suit.corner.nw, awful.layout.suit.corner.ne, awful.layout.suit.corner.sw, awful.layout.suit.corner.se} do
steps[#steps+1]=function()s.selected_tag.layout=native;return true end
steps[#steps+1]=function(n)
 local dump=awesome._clay_tree(s)
 if not dump:find('derived 0',1,true) then assert(n<30,dump);return end
 for line in dump:gmatch('[^\n]+') do
  if line:find('fixed(',1,true) then
   assert(line:find(' output ',1,true) or line:find(' theme',1,true)
    or line:find(' protocol',1,true) or line:find(' user',1,true) or line:find(' last%-frame'),line)
  end
 end
 io.stderr:write('[PASS] '..native.name..': derived 0; fixed inputs carry source words\n')
 return true
end
end
steps[#steps+1]=function()a:kill();b:kill();return true end
runner.run_steps(steps,{kill_clients=false})
