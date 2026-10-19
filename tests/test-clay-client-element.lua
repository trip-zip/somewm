-- luacheck: globals screen root awesome
-- Run: make test-one TEST=tests/test-clay-client-element.lua
local runner = require("_runner")
local utils = require("_utils")
local awful = require("awful")
local capture = require("_widget_capture")
local gsurface = require("gears.surface")

local TEST_CLIENT = utils.binary_or_skip("./build-test/test-transient-client")
if not TEST_CLIENT then
    return
end

local s = screen[1]
local c, frame, boxes, original_boxes, shadow_raster

local function box(x, y, w, h)
    return string.format("box %d,%d %dx%d ", x, y, w, h)
end

local function find(kind, wanted)
    for line in awesome._clay_tree(s):gmatch("[^\n]+") do
        if line:find(kind, 1, true) and line:find(wanted, 1, true) then
            return line
        end
    end
end

local function frame_box()
    return box(frame.x, frame.y, frame.width, frame.height)
end

-- The surface child sits inside the border ring.
local function surface_box()
    return box(frame.x + 4, frame.y + 4, frame.width - 8, frame.height - 8)
end

-- One native command grows from the client frame; the renderer partitions it.
local function shadow_boxes()
    return {box(frame.x - 8, frame.y - 4, frame.width + 16, frame.height + 16)}
end

local function assert_frame()
    assert(find("CUSTOM", surface_box()), "missing client surface")
    assert(find("BORDER", frame_box()), "missing client border")
    assert(not awesome._clay_tree(s):find("[tree!=scene]", 1, true),
        "the scene disagrees with the tree")
end

runner.run_steps({
    function(count)
        if count == 1 then
            awful.spawn(TEST_CLIENT)
        end
        c = utils.find_client_by_class("transient_test_parent")
        if c then
            return true
        end
    end,
    function()
        c.floating = true
        c.border_width = 4
        c:geometry({ x = s.geometry.x + 100, y = s.geometry.y + 100,
            width = 200, height = 120 })
        c.shadow = { enabled = true, radius = 8, offset_x = 0, offset_y = 4,
            spread = 0, corner_radius = 0, opacity = 1, color = "#ff0000" }
        local geo = c:geometry()
        frame = { x = geo.x - s.geometry.x, y = geo.y - s.geometry.y,
            width = geo.width + 8, height = geo.height + 8 }
        boxes = shadow_boxes()
        original_boxes = boxes
        return true
    end,
    function(count)
        if not find("CUSTOM", surface_box()) then
            assert(count < 20, "the client never reached the frame box")
            return
        end
        assert_frame()
        for _, wanted in ipairs(boxes) do
            local kind = "CUSTOM"
            assert(find(kind, wanted), "missing shadow " .. kind .. " at " .. wanted)
        end
        local r, g, b = capture.read(gsurface(root.content()),
            s.geometry.x + frame.x + math.floor(frame.width / 2),
            s.geometry.y + frame.y + frame.height + 2)
        assert(r == 255 and g == 0 and b == 0, "the shadow fill is not #ff0000")
        shadow_raster = assert(find("CUSTOM", boxes[1]):match("raster=(%d+)"),
            "the shadow has no raster byte count")
        io.stderr:write("[PASS] client frame and one native shadow command\n")
        return true
    end,
    function()
        local geo = c:geometry()
        c:geometry({ width = geo.width + 50 })
        frame.width = frame.width + 50
        boxes = shadow_boxes()
        return true
    end,
    function(count)
        if not find("CUSTOM", surface_box()) then
            assert(count < 20, "the resized client never reached the frame box")
            return
        end
        assert_frame()
        local top = assert(find("CUSTOM", boxes[1]), "missing resized shadow")
        assert(top:match("raster=(%d+)") == shadow_raster,
            "the shadow changed its tile footprint on resize")
        assert(find("CUSTOM", boxes[1]), "the solved shadow did not follow the resized frame")
        io.stderr:write("[PASS] resize stretches the strip and moves the corner\n")
        c.shadow = false
        return true
    end,
    function(count)
        for _, group in ipairs({ original_boxes, boxes }) do
            for _, wanted in ipairs(group) do
                if find("CUSTOM", wanted) then
                    assert(count < 20, "disabled shadow remains at " .. wanted)
                    return
                end
            end
        end
        assert_frame()
        io.stderr:write("[PASS] disabling the shadow keeps the client frame\n")
        c:kill()
        return true
    end,
    function(count)
        if not c.valid then
            return true
        end
        assert(count < 20, "the client did not exit")
    end,
}, { kill_clients = false })
