dofile(assert(os.getenv('SOMEWM_TEST_BASE_RC')))
local awful=require('awful')
local wibox=require('wibox')
local shape=require('gears.shape')
require('ruled').client.append_rule{rule={},properties={shape=shape.octogon}}
awful.screen.connect_for_each_screen(function(s)
    s.mask_box=wibox{screen=s,x=100,y=100,width=200,height=60,visible=true,
        bg='#204060',shape=shape.hexagon,shadow=false}
end)
