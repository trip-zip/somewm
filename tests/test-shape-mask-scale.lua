local runner=require('_runner')
local wibox=require('wibox')
local shape=require('gears.shape')
local color=require('gears.color')
local shot=require('_shape_mask_capture')
local box
local steps={function()
    root.wallpaper(color('#123456'))
    mouse.coords{x=600,y=300}
    box=wibox{x=100,y=100,width=80,height=60,visible=true,shadow=false,
        bg='#204060',shape=shape.hexagon}
    return true
end}
for _,scale in ipairs{2,1.5} do
    steps[#steps+1]=function() screen[1].scale=scale; return true end
    shot.check_steps(steps,function()
        return {{100,100,'#123456'},{179,100,'#123456'},
            {100,159,'#123456'},{179,159,'#123456'},{140,130,'#204060'}}
    end)
end
steps[#steps+1]=function() screen[1].scale=1; box.visible=false; return true end
runner.run_steps(steps)
