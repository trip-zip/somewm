local runner=require('_runner')
local awful=require('awful')
local wibox=require('wibox')
local naughty=require('naughty')
local example=require('_clay_example')
local popup, launcher, notification, bar, pid
local function box(width,height,color,placement,offset)
 return awful.popup {screen=screen[1],visible=true,ontop=true,bg=color,border_width=0,shadow=false,
  minimum_width=width,maximum_width=width,placement=placement,offset=offset,
  widget={widget=wibox.widget.textbox,text=' ',forced_height=height}}
end
runner.run_steps {
 function()
  require('gears.wallpaper').set('#123456')
  bar=awful.wibar {screen=screen[1],height=28,ontop=true,bg='#ff00ff',widget=wibox.widget.textbox('bar')}
  popup=box(320,80,'#ff0000',awful.placement.top_right,{x=-16,y=16})
  return true
 end,
 function(n)
  if n<3 then return end
  example.pixel(1030,18,'#ff0000') -- popup 80 over ontop bar 60
  local beautiful=require('beautiful');beautiful.notification_width=320;beautiful.notification_padding=16
  naughty.connect_signal('request::display',function(item)
   require('naughty.layout.box') {notification=item,border_width=0,shadow=false,bg='#00ff00',
    widget_template={widget=naughty.widget.message}}
  end)
  notification=naughty.notification {screen=screen[1],position='top_right',message='Band ninety',timeout=0}
  return true
 end,
 function(n)
  if n<3 then return end
  example.pixel(1030,18,'#00ff00') -- notification 90 over popup 80
  require('beautiful').launcher_width=1280
  launcher=box(1280,720,'#0000ff',awful.placement.centered)
  return true
 end,
 function(n)
  if n<3 then return end
  example.pixel(1030,18,'#0000ff') -- later declaration in band 90
  pid=awful.spawn {'./build-test/test-layer-client','--namespace','band-overlay','--layer','overlay',
   '--keyboard','none','--anchor','top,right','--size','240,120','--margins','16,12,0,0','--color','ffffff00'}
  return true
 end,
 function(n)
  if not awesome._clay_tree(screen[1]):find('band-overlay',1,true) or n<3 then assert(n<12);return end
  example.pixel(1030,18,'#ffff00') -- protocol overlay 100
  awesome.kill(pid,9);return true
 end,
 function(n)
  if n<3 then return end
  example.pixel(1030,18,'#0000ff');launcher.visible=false;return true
 end,
 function(n)
  if n<3 then return end
  example.pixel(1030,18,'#00ff00');notification:destroy();return true
 end,
 function(n)
  if n<3 then return end
  example.pixel(1030,18,'#ff0000');popup.visible=false;return true
 end,
 function(n)
  if n<3 then return end
  example.pixel(1030,18,'#ff00ff');bar.visible=false
  io.stderr:write('[PASS] root.content overlap: 60 < 80 < notification90 < later launcher90 < 100; removals reveal each lower band\n')
  return true
 end,
}
