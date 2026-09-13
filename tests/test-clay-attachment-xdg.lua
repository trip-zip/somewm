local runner=require('_runner')
local awful=require('awful')
local example=require('_clay_example')
local pid, parent
runner.run_steps {
 function() pid=awful.spawn {'./build-test/test-popup-client'};return true end,
 function(n)
  for _,c in ipairs(client.get()) do if c.class=='popup_test' then parent=c end end
  if not parent then assert(n<12);return end
  parent.floating=true;parent:geometry{x=200,y=200,width=200,height=200}
  return true
 end,
 function(n) if n<3 then return end;awesome.kill(pid,10);return true end,
 function(n)
  local d=awesome._clay_tree(screen[1])
  local line=d:match('[^\n]* popup [^\n]+')
  if not line then assert(n<12,d);return end
  assert(line:find('fixed(120)',1,true) and line:find('protocol',1,true)
   and line:find('attach ELEMENT',1,true) and line:find('band 80',1,true),line)
  local x,y,w,h=line:match('box (%-?%d+),(%-?%d+) (%d+)x(%d+)')
  assert(w=='120' and h=='120',line)
  example.pixel(tonumber(x)+2,tonumber(y)+2,'#4080c0')
  assert(tonumber(x)>=parent.x+parent.width and tonumber(y)>=parent.y+parent.height,
   'protocol popup must compose beyond parent surface')
  parent:kill();io.stderr:write('[PASS] task-1 XDG popup remains a protocol-sized surface float attached after its parent, with pixels outside parent\n')
  return true
 end,
}
