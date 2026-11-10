-- Content backing must not tint shared outer arcs on titlebars or the surface.
local f = require('_frame_capture').new('borderless_fringe', 0)

local function check(read, scale, box)
    local left, top = math.floor(box.x * scale), math.floor(box.y * scale)
    local right = math.floor((box.x + box.w) * scale) - 1
    local radius = math.floor(f.radius * scale)
    local blended, worst, where = 0, 0, ''
    for _, corner in ipairs{{left, 1}, {right, -1}} do
        for dy = 0, radius - 1 do
            for dx = 0, radius - 1 do
                local x, y = corner[1] + corner[2] * dx, top + dy
                local r, g, b = read(x, y)
                -- Both visible colors are gray. Any blend of the titlebar
                -- and wallpaper remains gray, regardless of arc coverage.
                local spread = math.max(r, g, b) - math.min(r, g, b)
                if spread > worst then
                    worst, where = spread, string.format('%d,%d #%02x%02x%02x', x, y, r, g, b)
                end
                if r > 40 and r < 120 then blended = blended + 1 end
            end
        end
    end
    assert(blended > 0, 'outer arc has no antialiased samples')
    assert(worst <= 2, string.format('content fill tints outer arc at %s (channel spread %d)', where, worst))
end

for _, scale in ipairs{1, 1.5} do
    local baseline = {}
    local function check_edges(read, pixel_scale, box, remember)
        check(read, pixel_scale, box)
        local radius = math.floor(f.radius * pixel_scale)
        local left = math.floor(box.x * pixel_scale)
        local right = math.floor((box.x + box.w) * pixel_scale) - 1
        local bottom = math.floor((box.y + box.h) * pixel_scale) - 1
        local pixels, worst, where = {}, 0, ''
        for _, corner in ipairs{{left, 1}, {right, -1}} do
            for dy = 0, radius - 1 do
                for dx = 0, radius - 1 do
                    local x, y = corner[1] + corner[2] * dx, bottom - dy
                    local pixel = {read(x, y)}
                    pixels[#pixels + 1] = pixel
                    if not remember then
                        local expected = assert(baseline[pixel_scale])[#pixels]
                        for channel = 1, 3 do
                            local delta = math.abs(pixel[channel] - expected[channel])
                            if delta > worst then
                                worst, where = delta, string.format('%d,%d', x, y)
                            end
                        end
                    end
                end
            end
        end
        if remember then baseline[pixel_scale] = pixels end
        assert(worst <= 2, string.format('backing changes shared content arc at %s by %d', where, worst))
    end
    local function remember(read, pixel_scale, box) check_edges(read, pixel_scale, box, true) end
    f:stage('no independent rounding', scale, function(c)
        c.content_radius, c.content_background_color = 0, nil
    end, '0,0,24,24', remember, f.ink)
    f:stage('contrasting border fill', scale, function(c) c.content_radius = 24 end,
        '24,24,24,24', check_edges, f.border)
    f:stage('contrasting explicit fill', scale, function(c) c.content_background_color = '#00ff00' end,
        '24,24,24,24', check_edges, '#00ff00')
    f:stage('matching fill', scale, function(c) c.content_background_color = f.bar_color end,
        '24,24,24,24', check_edges, f.bar_color)
    f:stage('disable independent rounding', scale, function(c)
        c.content_radius, c.content_background_color = nil, '#00ff00'
    end, '0,0,24,24', check_edges, f.ink)
end
f:run()
