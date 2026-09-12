local runner=require('_runner')
local awful=require('awful')
local utils=require('_utils')
local capture=require('_widget_capture')
local surface=require('gears.surface')
local golden=require('_clay_example')
local a,b,c,bar,before
local reports={os.tmpname(),os.tmpname(),os.tmpname()}
local function pixel(x,y)
 local r,g,b=capture.read(surface(root.content()),x,y)
 return string.format('#%02x%02x%02x',r,g,b)
end
local function line(c)
 return assert(awesome._clay_tree(screen[1]):match('\n(  CLIENT '..c.class..' [^\n]+)'), 'missing float '..c.class)
end
local function wait(fn)
 return function(n)
  local ok,err=pcall(fn)
  if ok then return true end
  if tostring(err):find('tests/goldens/',1,true) then error(err) end
  assert(n<15,err)
 end
end
local function blocks()
 local parts,head={},{}
 local key
 for l in golden.shape(awesome._clay_tree(screen[1])):gmatch('[^\n]+') do
  local name=l:match('^  CLIENT (%S+) ')
  if name then key=name; parts[key]={} end
  local target=key and parts[key] or head
  target[#target+1]=l
 end
 local keys={}; for k in pairs(parts) do keys[#keys+1]=k end;table.sort(keys)
 for _,k in ipairs(keys) do head[#head+1]=table.concat(parts[k],'\n') end
 return table.concat(head,'\n')
end
runner.run_steps({
 function()
  screen[1].selected_tag.layout=awful.layout.suit.tile
  bar=awful.wibar{screen=screen[1],position='top',height=32,bg='#0000ff'}
  for i,name in ipairs{'band_tile','band_red','band_blue'} do
   awful.spawn{'./build-test/test-transient-client',name,reports[i],'0',({'ff204060','ffcc3300','ff0033cc'})[i]}
  end
  return true
 end,
 function(n)
  a=utils.find_client_by_class('band_tile');b=utils.find_client_by_class('band_red');c=utils.find_client_by_class('band_blue')
  if not a or not b or not c then assert(n<30,'clients did not map');return end
  a.floating=false
  for _,obj in ipairs{a,b,c} do obj.shadow=false;obj.border_width=1 end
  for _,obj in ipairs{b,c} do
   obj.floating=true;obj:geometry{x=0,y=0,width=200,height=160}
   awful.titlebar(obj,{size=24,bg_normal='#ffff00',bg_focus='#ffff00'})
  end
  b:raise();c:raise()
  return true
 end,
 wait(function()
  assert(line(b):find('w=fixed(202) h=fixed(186) user',1,true),'float dimensions must be user inputs')
  assert(line(b):find('attach OUTPUT offset 0,0 band 20',1,true),'float attachment')
  assert(pixel(50,100)=='#0033cc','float not above tile or raise order wrong')
  assert(pixel(50,16)=='#ffff00','float titlebar not above normal wibar')
  assert(pixel(500,16)=='#0000ff','tiled client not below normal wibar')
  golden.check('bands-normal',awesome._clay_tree(screen[1]))
  before=blocks()
  io.stderr:write('[PASS] user float attached OUTPUT band 20, pixels above tile and normal wibar\n')
 end),
 function()b:raise();return true end,
 wait(function()
  assert(pixel(50,100)=='#cc3300','raise did not change pixels')
  golden.check('bands-raised',awesome._clay_tree(screen[1]))
  assert(blocks()==before,'raise changed more than declaration order')
  local dump=awesome._clay_tree(screen[1]); assert(dump:find('CLIENT band_blue',1,true)<dump:find('CLIENT band_red',1,true),'raise declaration order')
  io.stderr:write('[PASS] raise changes only declaration order and top pixel\n')
 end),
 function()bar.ontop=true;return true end,
 wait(function()
  assert(pixel(50,16)=='#0000ff' and pixel(500,16)=='#0000ff','ontop wibar not above float and tile')
  golden.check('bands-ontop',awesome._clay_tree(screen[1]))
  io.stderr:write('[PASS] ontop wibar pixels above floating and tiled clients\n')
 end),
 function()b.fullscreen=true; b:activate{context='test',raise=true};return true end,
 wait(function()
  local l=line(b)
  assert(l:find('w=grow h=grow',1,true) and l:find('band 40',1,true),'fullscreen must grow at 40')
  assert(l:find('box 0,0 1280x720',1,true),'fullscreen solved size')
  assert(pixel(500,400)=='#cc3300','fullscreen does not fill output')
  assert(pixel(50,16)=='#0000ff','ontop bar must remain above fullscreen')
  local f=assert(io.open(reports[2]));local sizes=f:read('*a');f:close()
  assert(sizes=='1280 720\n','fullscreen configure differs from solved surface')
  golden.check('floating-and-fullscreen-clients',awesome._clay_tree(screen[1]))
  io.stderr:write('[PASS] fullscreen grow x grow band 40, received 1280x720\n')
 end),
 function()
  for _,obj in ipairs{a,b,c} do obj:kill() end
  for _,p in ipairs(reports) do os.remove(p) end
  bar.visible=false;return true
 end,
},{kill_clients=false})
