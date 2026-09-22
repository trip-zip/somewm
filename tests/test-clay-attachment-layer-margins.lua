local runner=require('_runner')
local awful=require('awful')
local example=require('_clay_example')
local pid, report=os.tmpname(),os.tmpname()
local function launch(anchor,size,margins)
 pid=awful.spawn {'./build-test/test-layer-client','--namespace','margin-overlay','--layer','overlay',
  '--keyboard','none','--anchor',anchor,'--size',size,'--margins',margins,
  '--configure-report',report,'--color','ff0000ff'}
end
runner.run_steps {
 function() require('gears.wallpaper').set('#123456'); launch('top,left,right','0,80','10,12,0,-16'); return true end,
 function(n)
  local d=awesome._clay_tree(screen[1])
  local f=io.open(report);local size=f and f:read('*a');if f then f:close() end
  if size~='1284 80\n' then assert(n<12,tostring(size));return end
  assert(d:find('box -16,10 1284x80',1,true),d)
  example.pixel(0,12,'#0000ff');example.pixel(1266,12,'#0000ff');example.pixel(1270,12,'#123456')
  awesome.kill(pid,15);return true
 end,
 function(n) if n<3 then return end;launch('','240,120','30,40,50,60');return true end,
 function(n)
  local d=awesome._clay_tree(screen[1])
  if not d:find('box 520,300 240x120',1,true) then assert(n<12,d);return end
  local f=assert(io.open(report));assert(f:read('*a')=='240 120\n');f:close()
  example.pixel(522,302,'#0000ff');example.pixel(518,302,'#123456')
  awesome.kill(pid,15);os.remove(report)
  io.stderr:write('[PASS] negative stretch margins and ignored unanchored margins: solved pixels/configures\n')
  return true
 end,
}
