local runner=require('_runner')
local awful=require('awful')
local wibox=require('wibox')
local example=require('_clay_example')
local popup
runner.run_steps {
 function()
  require('gears.wallpaper').set('#ffffff')
  popup=awful.popup {screen=screen[1],x=100,y=100,ontop=true,visible=true,bg='#ff0000',
   border_width=3,border_color='#0000ff',
   shadow={radius=6,offset_x=6,offset_y=6,spread=0,corner_radius=0,opacity=1,color='#000000'},
   placement=awful.placement.centered, minimum_width=80, maximum_width=80,
   widget={widget=wibox.widget.textbox,text=' ',forced_width=80,forced_height=40}}
  return true
 end,
 function(n)
  if n<4 then return end
  local g=popup:geometry()
  example.pixel(g.x+10,g.y+10,'#ff0000')
  example.pixel(g.x-1,g.y+10,'#0000ff')
  local r,green,b=require('_widget_capture').read(require('gears.surface')(root.content()),g.x+g.width+5,g.y+20)
  assert(r<220 and green<220 and b<220,'popup shadow missing')
  popup.visible=false
  io.stderr:write('[PASS] attached popup retains outside border and shadow pixels\n')
  return true
 end,
}
