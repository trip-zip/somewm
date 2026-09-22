-- Run: make test-one TEST=tests/test-clay-only-on-screen.lua
local runner = require("_runner")
local awful = require("awful")
local wibox = require("wibox")
local leaf_widget = require("_widget_capture").leaf_widget
local s = screen[1]
local bar, container

local function lines()
    local out = {}
    for line in awesome._clay_tree(s):gmatch("[^\n]+") do
        out[#out + 1] = line
    end
    return out
end

local function block(bar)
    local d = bar.drawin
    local want = string.format("  drawin screen %d %dx%d+%d+%d ", s.index,
        d.width, d.height, d.x, d.y)
    local head, nodes = nil, {}

    for _, line in ipairs(lines()) do
        if head then
            local id, indent, class = line:match("^    (%x+) ( *)([%w_.-]+)")
            if not id then
                break
            end
            nodes[#nodes + 1] = {
                id = id, depth = #indent / 2, class = class, line = line,
            }
        elseif line:sub(1, #want) == want then
            head = line
        end
    end
    return head, nodes
end

local function node_named(nodes, class)
    for _, node in ipairs(nodes) do
        if node.class == class then
            return node
        end
    end
    return nil
end

local steps = {
    function(count)
        if count == 1 then
            bar = wibox { x = 0, y = 0, width = 400, height = 24,
                screen = s, bg = "#101010", visible = true }
            bar:setup {
                layout = wibox.layout.fixed.horizontal,
                { leaf_widget(40, nil, "#ff0000"), screen = s,
                    widget = awful.widget.only_on_screen },
                leaf_widget(30, nil, "#0000ff"),
            }
            container = bar.widget:get_children()[1]
            return nil
        end
        local head, nodes = block(bar)
        local boxes = awesome._test_widget_boxes(bar.drawin)
        if not head or #boxes == 0 then
            assert(count < 20, "the bar never declared its tree")
            return nil
        end
        assert(head:find("converted", 1, true), head)
        assert(node_named(nodes, "awful.widget.only_on_screen"), "the container is missing")
        assert(#boxes == 5 and boxes[3].width == 40 and boxes[5].x == 40,
            "the displayed container did not reserve 40 pixels")
        io.stderr:write("[PASS] only_on_screen describes its displayed child\n")
        return true
    end,
    function(count)
        if count == 1 then
            container.screen = screen.count() + 1
            return nil
        end
        local boxes = awesome._test_widget_boxes(bar.drawin)
        if #boxes == 4 and boxes[3].width == 0 and boxes[4].x == 0 then
            io.stderr:write("[PASS] an invalid screen hides the child and takes no width\n")
            return true
        end
        assert(count < 20, "the hidden container did not release its width")
    end,
    function(count)
        if count == 1 then
            container.screen = s
            return nil
        end
        local boxes = awesome._test_widget_boxes(bar.drawin)
        if #boxes == 5 and boxes[5].x == 40 then
            io.stderr:write("[PASS] restoring the screen restores the child and width\n")
            bar.visible = false
            return true
        end
        assert(count < 20, "the container did not recover its child")
    end,
}

runner.run_steps(steps)
