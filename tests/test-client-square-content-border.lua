-- Square surface corners must not cover the curved part of the frame border.
local f = require('_frame_capture').new('square_content_border', 2)

local function check(read, scale, box)
    local function pixel(x, y, expected, label)
        local px, py = math.floor((x + .5) * scale), math.floor((y + .5) * scale)
        local r, g, b = read(px, py)
        local actual = string.format('#%02x%02x%02x', r, g, b)
        assert(actual == expected, string.format('%s at %d,%d: %s, want %s',
            label, px, py, actual, expected))
    end
    pixel(box.x + 100, box.y + 1, f.border, 'straight border')
    pixel(box.x + 64, box.y + 96, f.ink, 'content')
    pixel(box.x, box.y, f.wallpaper, 'outside outer arc')
    -- The diagonal sample is 23.33 pixels from the 24-pixel arc's center,
    -- inside the two-pixel border and away from both antialiased edges.
    for _, corner in ipairs{
        {box.x + 7, box.y + 7, 'top-left'},
        {box.x + box.w - 8, box.y + 7, 'top-right'},
        {box.x + 7, box.y + box.h - 8, 'bottom-left'},
        {box.x + box.w - 8, box.y + box.h - 8, 'bottom-right'},
    } do
        pixel(corner[1], corner[2], f.border, corner[3] .. ' border arc')
    end
end

for _, scale in ipairs{1, 1.5} do
    f:stage('shape-derived corners', scale, function(c) c.content_radius = nil end,
        '0,0,22,22', check)
    f:stage('explicit square content', scale, function(c) c.content_radius = {} end,
        nil, check)
    f:stage('square bottom corners', scale, function(c)
        c.content_radius = {top_left = 24, top_right = 24}
    end, '24,24,0,0', check)
    f:stage('restore shape-derived corners', scale, function(c) c.content_radius = 0 end,
        '0,0,22,22', check)
    f:stage('tiled square content without animation policy', scale, function(c)
        c.floating, c.content_radius = false, {}
    end, nil, check)
    f:stage('floating square content without animation policy', scale, function(c)
        c.floating = true
        c:geometry{x = 100, y = 100, width = 300, height = 220}
    end, nil, check)
end
f:run()
