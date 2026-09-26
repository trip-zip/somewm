local runner = require("_runner")
local awful = require("awful")
local wibox = require("wibox")
local gears = require("gears")
local utils = require("_utils")

local s = screen[1]
local geo = s.geometry
local clients, reports = {}, {}
local old_layout = s.selected_tag.layout
local old_factor = s.selected_tag.master_width_factor

local function background(width, height)
    return wibox.widget {
        bg = "#336699", forced_width = width, forced_height = height,
        widget = wibox.container.background,
    }
end

local function realized(dump)
    local lines, inside = {}, false
    for line in dump:gmatch("[^\n]+") do
        if line == "  realized:" then
            inside = true
        elseif line:match("^output ") then
            inside = false
        elseif inside then
            lines[#lines + 1] = line
        end
    end
    return lines
end

local function print_realized_diff(before, after)
    local a, b = realized(before), realized(after)
    local lengths = {}
    lengths[#a + 1] = {}
    for j = 1, #b + 1 do lengths[#a + 1][j] = 0 end
    for i = #a, 1, -1 do
        lengths[i] = { [#b + 1] = 0 }
        for j = #b, 1, -1 do
            lengths[i][j] = a[i] == b[j] and lengths[i + 1][j + 1] + 1
                or math.max(lengths[i + 1][j], lengths[i][j + 1])
        end
    end
    local i, j = 1, 1
    while i <= #a or j <= #b do
        if i <= #a and j <= #b and a[i] == b[j] then
            i, j = i + 1, j + 1
        elseif i <= #a and (j > #b or lengths[i + 1][j] >= lengths[i][j + 1]) then
            io.stderr:write("- " .. a[i] .. "\n")
            i = i + 1
        else
            io.stderr:write("+ " .. b[j] .. "\n")
            j = j + 1
        end
    end
end

local function print_scroll(stage)
    local root = awful.layout.suit.carousel._test.get_state(s.selected_tag).publish
    if not root or not root.id then
        io.stderr:write("[SCROLL] carousel-focus " .. stage .. " unpublished\n")
        return
    end
    local x, y, width, height, box_width, box_height = awesome._clay_scroll_get(s, root.id)
    io.stderr:write(string.format("[SCROLL] carousel-focus %s %s,%s,%s,%s,%s,%s\n",
        stage, tostring(x), tostring(y), tostring(width), tostring(height),
        tostring(box_width), tostring(box_height)))
end

local function frames(dump)
    return assert(tonumber(dump:match("output %S+ scale [^\n]* frames (%d+)")))
end

local function measure(trigger, before_frames, follows)
    if trigger == "carousel-focus" then print_scroll("before-first") end
    local dump = awesome._clay_tree(s)
    if frames(dump) == before_frames then
        awesome._test_redeclare()
        dump = awesome._clay_tree(s)
    end
    local header, counts = dump:match("([^\n]*output %S+ scale [^\n]*)\n([^\n]*)")
    local n = tonumber((header or ""):match(" frames %d+ passes (%d+)"))
    io.stderr:write(string.format("[PASSES] %s %s\n%s\n%s\n", trigger, tostring(n),
        header or "missing the output header", counts or "missing the counters"))
    if trigger == "carousel-focus" then print_scroll("after-first") end
    assert(n, trigger .. ": missing passes counter")
    for i = 1, follows or 0 do
        local before = awesome._clay_tree(s)
        local mutations = awesome._test_redeclare()
        local after = awesome._clay_tree(s)
        io.stderr:write(string.format("[FOLLOWS] %s %d %d\n", trigger, i, mutations))
        print_realized_diff(before, after)
        assert(i > 1 or mutations > 0, trigger .. ": the follow-up frame mutated no nodes")
    end
    assert(trigger == "grid-grow" and n <= 4 or n == 1, trigger .. ": passes " .. n)
    return awesome._clay_tree(s)
end

local function check_mutations(trigger)
    local before = awesome._clay_tree(s)
    local mutations = awesome._test_redeclare()
    local after = awesome._clay_tree(s)
    io.stderr:write(string.format("[MUTATIONS] %s %d\n", trigger, mutations))
    if trigger == "carousel-focus" then print_scroll("after-second") end
    if mutations ~= 0 then print_realized_diff(before, after) end
    if trigger == "carousel-focus" then
        io.stderr:write("[KNOWN] carousel-focus: record past the clamp, TASK-44\n")
    else
        assert(mutations == 0, trigger .. ": the settled frame mutated " .. mutations
            .. " nodes")
    end
    return after
end

local steps = {}

local function add_trigger(name, setup, change, follows)
    local cleanup, cleanup_done, settled, before_frames
    steps[#steps + 1] = setup
    steps[#steps + 1] = function()
        before_frames = frames(awesome._clay_tree(s))
        cleanup = change()
        return true
    end
    steps[#steps + 1] = function()
        measure(name, before_frames, follows)
        settled = check_mutations(name)
        return true
    end
    steps[#steps + 1] = function(count)
        if count < 6 then return end
        local after = awesome._clay_tree(s)
        local settled_frames, after_frames = frames(settled), frames(after)
        io.stderr:write(string.format("[SETTLED] %s frames %d -> %d\n",
            name, settled_frames, after_frames))
        if settled_frames ~= after_frames then
            io.stderr:write(after:match("([^\n]*output %S+ scale [^\n]*\n[^\n]*)") .. "\n")
            print_realized_diff(settled, after)
        end
        assert(settled_frames == after_frames, name .. ": trigger frame scheduled work")
        return true
    end
    steps[#steps + 1] = function(count)
        if count < 6 then return end
        local after = awesome._clay_tree(s)
        local settled_frames, after_frames = frames(settled), frames(after)
        io.stderr:write(string.format("[IDLE] %s frames %d -> %d\n",
            name, settled_frames, after_frames))
        if settled_frames ~= after_frames then
            io.stderr:write(after:match("([^\n]*output %S+ scale [^\n]*\n[^\n]*)") .. "\n")
            print_realized_diff(settled, after)
        end
        assert(settled_frames == after_frames, name .. ": settled frame scheduled work")
        return true
    end
    steps[#steps + 1] = function(count)
        if count == 1 then
            cleanup_done = cleanup and cleanup()
            return
        end
        if not cleanup_done or cleanup_done(count) then return true end
        assert(count < 50, name .. ": cleanup did not finish by count 50")
    end
end

local popup
add_trigger("popup-open", function()
    popup = awful.popup {
        screen = s, visible = false, placement = awful.placement.top_left,
        widget = background(300, 80),
    }
    return true
end, function()
    popup.visible = true
    return function() popup.visible = false end
end)

local bar
add_trigger("wibar-appear", function()
    assert(s.workarea.y == geo.y and s.workarea.height == geo.height,
        "the screen already has a vertical reservation")
    bar = awful.wibar { screen = s, position = "top", height = 40, visible = false,
        widget = background(nil, 40) }
    return true
end, function()
    bar.visible = true
    return function() bar:remove() end
end)

local content, overflow_box
add_trigger("overflow-grow", function()
    content = background(nil, 50)
    local overflow = wibox.layout.overflow.vertical()
    overflow:add(content)
    overflow.scrollbar_enabled = true
    overflow.scrollbar_widget = wibox.widget.separator {
        shape = gears.shape.rectangle, color = "#ffffff",
    }
    overflow_box = wibox { screen = s, visible = true,
        x = geo.x + 100, y = geo.y + 100, width = 200, height = 100,
        widget = overflow }
    return true
end, function()
    content.forced_height = 400
    return function() overflow_box.visible = false end
end, 2)

steps[#steps + 1] = function(count)
    if count == 1 then
        local binary = assert(utils.binary_or_skip("./build-test/test-transient-client"))
        for i = 1, 3 do
            reports[i] = os.tmpname()
            awful.spawn { binary, "FRAME_PASSES_" .. i, reports[i], "0", "ff336699", "0" }
        end
    end
    for i = 1, 3 do
        clients[i] = utils.find_client_by_class("FRAME_PASSES_" .. i)
        if not clients[i] then
            assert(count < 20, "carousel client did not map")
            return nil
        end
    end
    for _, c in ipairs(clients) do
        c.floating, c.shadow, c.border_width = false, false, 0
        c.carousel_column_width = 0.75
    end
    s.selected_tag.layout = awful.layout.suit.carousel
    client.focus = clients[1]
    return true
end

add_trigger("carousel-focus", function()
    awful.layout.suit.carousel.focus_first_column()
    return true
end, function()
    awful.layout.suit.carousel.focus_last_column()
end)

add_trigger("tile-master-width", function()
    s.selected_tag.layout = awful.layout.suit.tile
    return true
end, function()
    s.selected_tag.master_width_factor = 0.65
    return function()
        s.selected_tag.layout = old_layout
        s.selected_tag.master_width_factor = old_factor
        for _, c in ipairs(clients) do c:kill() end
        local empty_count
        return function(count)
            if #client.get() ~= 0 then
                empty_count = nil
                return false
            end
            empty_count = empty_count or count
            return count - empty_count >= 2
        end
    end
end)

add_trigger("inspector-close", function(count)
    if count == 1 then s.inspector = true end
    if awesome._clay_tree(s):match("output %S+ scale [%d.]+ inspector on") then
        return true
    end
end, function()
    local x, y = geo.x + geo.width - 20, geo.y + 15
    root.fake_input("motion_notify", false, x, y)
    root.fake_input("motion_notify", false, x, y)
    root.fake_input("button_press", 1)
    root.fake_input("button_release", 1)
    return function()
        assert(not s.inspector, "the x button did not close the inspector")
    end
end)

local grid, grid_box
add_trigger("grid-grow", function()
    grid = wibox.layout.grid()
    grid.spacing = 5
    grid:add_widget_at(background(20, 10), 1, 1)
    grid_box = wibox { screen = s, visible = true,
        x = geo.x + 100, y = geo.y + 100, width = 200, height = 100,
        widget = grid }
    return true
end, function()
    grid:add_widget_at(background(40, 10), 1, 2)
    grid:add_widget_at(background(30, 10), 1, 3)
    return function() grid_box.visible = false end
end)

local tooltip_bar, tooltip_target, tooltip
add_trigger("tooltip-open", function()
    tooltip_target = wibox.widget.textbox("wifi")
    tooltip_bar = awful.wibar { screen = s, position = "top", height = 28,
        widget = tooltip_target }
    tooltip = awful.tooltip { objects = { tooltip_target },
        text = "Connected to Home Wi-Fi", mode = "outside",
        preferred_positions = { "bottom" }, preferred_alignments = { "middle" },
        gaps = 6, margin_leftright = 4, margin_topbottom = 4,
        bg = "#ff0000", border_width = 0, shape = gears.shape.rectangle }
    return true
end, function()
    root.fake_input("motion_notify", false, geo.x + 12, geo.y + 12)
    tooltip_target:emit_signal("mouse::enter")
    return function()
        assert(tooltip.visible and tooltip.wibox.width > 1 and tooltip.wibox.height > 1,
            "the frame did not show and size the tooltip")
        tooltip.hide()
        tooltip_bar:remove()
    end
end, 1)

steps[#steps + 1] = function()
    for _, report in ipairs(reports) do os.remove(report) end
    return true
end

runner.run_steps(steps, { wait_per_step = 6 })
