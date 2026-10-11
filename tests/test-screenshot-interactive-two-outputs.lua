-- Test: an interactive screenshot started with the pointer on the second
-- output draws its frame and selection rectangle on that output, and selects
-- the root-space box the drag covers. Needs two outputs (the two-output lane
-- in tests/README.md).

local awful  = require("awful")
local ipc    = require("awful.ipc")
local runner = require("_runner")
local async  = require("_async")
local utils  = require("_utils")
local gfs    = require("gears.filesystem")

local awful_screenshot = require("awful.screenshot")

if screen.count() < 2 then
    return runner.skip("test-screenshot-interactive-two-outputs requires WLR_HEADLESS_OUTPUTS=2")
end

local VPOINTER = utils.binary_or_skip("./build-test/test-virtual-pointer-client")
if not VPOINTER then return end

-- Grab the instance the IPC handler creates, as test-screenshot-interactive-ipc.lua does.
local original_meta = getmetatable(awful_screenshot) or {}
local captured_ss = nil
local new_meta = {}
for k, v in pairs(original_meta) do new_meta[k] = v end
new_meta.__call = function(cls, args)
    captured_ss = original_meta.__call(cls, args)
    return captured_ss
end
setmetatable(awful_screenshot, new_meta)

-- Stub _ipc_send_response so the test can read the deferred reply.
local captured_response = nil
_G._ipc_send_response = function(_, response)
    captured_response = response
end

local SEPARATOR = "\n%s+%x+ wibox%.widget%.separator [^\n]*"

runner.run_async(function()
    local g1, g2 = screen[1].geometry, screen[2].geometry
    local w, h = root.size()
    io.stderr:write(string.format("screen[1] %d,%d %dx%d screen[2] %d,%d %dx%d root %dx%d\n",
        g1.x, g1.y, g1.width, g1.height, g2.x, g2.y, g2.width, g2.height, w, h))

    -- Snipping starts on the screen under the pointer.
    local cx, cy = g2.x + math.floor(g2.width / 2), g2.y + math.floor(g2.height / 2)
    awful.spawn(string.format("%s move %d %d %d %d", VPOINTER, cx, cy, w, h))
    assert(async.wait_for_condition(function()
        local c = mouse.coords()
        return c.x == cx and c.y == cy
    end, 5), "the pointer never reached the second screen's centre")
    assert(mouse.screen == screen[2], "the pointer is not on screen 2")

    local path = os.tmpname()
    os.remove(path)
    path = path .. ".png"

    assert(ipc.dispatch("screenshot interactive " .. path, 4321) == nil,
        "dispatch should defer its response")
    assert(captured_ss, "no awful.screenshot instance was created")

    local selected = nil
    captured_ss:connect_signal("property::selected_geometry", function(_, geo)
        selected = geo
    end)

    local x1, y1 = g2.x + 100, g2.y + 120
    awful.spawn(string.format("%s drag %d %d %d %d %d %d 1500",
        VPOINTER, x1, y1, x1 + 200, y1 + 150, w, h))

    -- The dump is output-local: the box sits at the drag's offset into screen 2.
    local dump, line
    local drawn = async.wait_for_condition(function()
        dump = awesome._clay_tree(screen[2])
        line = dump:match(SEPARATOR)
        return line and line:find("w=fixed(200) user h=fixed(150) user", 1, true)
            and line:find("box 100,120 200x150", 1, true)
    end, 1.2, 0.05)
    assert(drawn, "the selection rectangle is not 200x150 at 100,120 on screen 2: "
        .. tostring(line) .. "\n" .. dump)
    io.stderr:write("matched:" .. line .. "\n" .. dump .. "\n")

    local dump1 = awesome._clay_tree(screen[1])
    assert(not dump1:match(SEPARATOR), "the selection rectangle is on screen 1:\n" .. dump1)

    assert(async.wait_for_condition(function() return captured_response ~= nil end, 5),
        "the release never finished the screenshot")
    assert(captured_response:match("^OK"), "expected OK, got: " .. captured_response)
    assert(selected and selected.x == x1 and selected.y == y1
        and selected.width == 200 and selected.height == 150,
        string.format("selected_geometry is not 200x150 at %d,%d", x1, y1))
    assert(gfs.file_readable(path), "no png at " .. path)
    os.remove(path)

    io.stderr:write("[PASS] the drag on screen 2 draws there and saves its root-space geometry\n")
    runner.done()
end)
