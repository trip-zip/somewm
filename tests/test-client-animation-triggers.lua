local runner = require('_runner')
local async = require('_async')
local awful = require('awful')
local beautiful = require('beautiful')
local ruled = require('ruled')
local utils = require('_utils')
local binary = assert(utils.binary_or_skip('./build-test/test-transient-client'))
local s = screen[1]

local function dump()
    local text = awesome._clay_tree(s)
    assert(not text:find('[tree!=scene]', 1, true), text)
    return text
end

local function box(c)
    for line in dump():gmatch('[^\n]+') do
        if line:find('CLIENT ' .. c.class .. ' ', 1, true) then
            local x, y, w, h = line:match('box (%-?%d+),(%-?%d+) (%d+)x(%d+)')
            return {tonumber(x), tonumber(y), tonumber(w), tonumber(h)}
        end
    end
    error('missing client ' .. c.class)
end

local function exact(c, wanted)
    local actual = box(c)
    assert(table.concat(actual, ',') == table.concat(wanted, ','),
        c.class .. ': ' .. table.concat(actual, ',') .. ' expected ' .. table.concat(wanted, ','))
end

runner.run_async(function()
    beautiful.animation_maximize_duration = 1
    beautiful.animation_layout_duration = 0
    local t = s.selected_tag
    t.layout = awful.layout.suit.tile
    t.master_width_factor = .5
    t.gap = 0
    local ruled_before_arrange = false
    ruled.client.append_rule {
        rule = {class = 'ANIMATION_DISABLED'},
        properties = {animate = false, floating = false, border_width = 0},
        callback = function(c)
            assert(c.animate == false, 'rule did not store animate')
        end,
    }
    local function arranged()
        local c = utils.find_client_by_class('ANIMATION_DISABLED')
        if c then
            assert(c.animate == false, 'animate rule missed the first arrange')
            ruled_before_arrange = true
        end
    end
    s:connect_signal('arrange', arranged)
    local reports = {}
    local function spawn(class)
        local report = os.tmpname()
        reports[#reports + 1] = report
        awful.spawn {binary, class, report, '0', 'ff0000cc', '0'}
        for _ = 1, 100 do
            local c = utils.find_client_by_class(class)
            if c then
                c.floating, c.shadow = false, false
                return c
            end
            async.sleep(.02)
        end
        error('client did not map: ' .. class)
    end
    local c = spawn('ANIMATION_ENABLED')
    local other = spawn('ANIMATION_DISABLED')
    async.sleep(.3)
    assert(ruled_before_arrange, 'no arrange observed after applying rule')
    local before = box(c)
    local wa = s.workarea
    local target = {wa.x, wa.y, wa.width, wa.height}
    assert(before[3] < target[3], 'client already spans workarea')
    c.maximized = true
    async.sleep(.3)
    local middle = box(c)
    assert(middle[3] > before[3] and middle[3] < target[3],
        'maximize did not interpolate: ' .. table.concat(middle, ','))
    async.sleep(.9)
    exact(c, target)
    other.minimized = true
    c.maximized = false
    async.sleep(1.2)
    exact(c, target)
    beautiful.animation_layout_duration = 0
    t.gap = 20
    async.sleep(.02)
    local inset = {wa.x + 20, wa.y + 20, wa.width - 40, wa.height - 40}
    exact(c, inset)
    beautiful.animation_layout_duration = nil
    local layout_animation = require('somewm.layout_animation')
    layout_animation.duration = .5
    t.gap = 0
    async.sleep(.1)
    local gap_middle = box(c)
    assert(gap_middle[3] > inset[3] and gap_middle[3] < target[3],
        'gap did not use the layout duration: ' .. table.concat(gap_middle, ','))
    async.sleep(.5)
    exact(c, target)
    beautiful.animation_layout_duration = 0
    other.minimized = false
    c.animate = false
    c.maximized = false
    c:swap(other)
    async.sleep(.1)
    c.animate = nil
    t.master_width_factor = .7
    async.sleep(.02)
    local widths = {box(c)[3], box(other)[3]}
    table.sort(widths)
    assert(widths[1] == 384 and widths[2] == 896,
        'layout did not snap: ' .. table.concat(widths, ',') .. '\n' .. dump())
    other.maximized = true
    async.sleep(.02)
    exact(other, target)
    async.sleep(.3)
    local idle = assert(dump():match('output %S+ scale [^\n]* frames (%d+)'))
    async.sleep(.5)
    assert(dump():match('output %S+ scale [^\n]* frames (%d+)') == idle,
        'the band kept framing while idle')
    s:disconnect_signal('arrange', arranged)
    c:kill()
    other:kill()
    for _, report in ipairs(reports) do os.remove(report) end
    io.stderr:write('[PASS] client animation triggers: maximize, layout, rule and idle\n')
    runner.done()
end)
