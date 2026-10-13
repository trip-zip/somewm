-- Test: an interactive screenshot draws the selection rectangle a drag
-- selects. test-virtual-pointer-client holds the button from press to
-- release in one process, so no other pointer input reaches the grabber
-- between the press and the dump.

local awful  = require("awful")
local ipc    = require("awful.ipc")
local runner = require("_runner")
local async  = require("_async")
local utils  = require("_utils")

local awful_screenshot = require("awful.screenshot")

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

local function log_contents()
    io.stderr:flush()
    local file = assert(io.open(assert(os.getenv("SOMEWM_TEST_LOG")), "r"))
    local contents = file:read("*a")
    file:close()
    return contents
end

runner.run_async(function()
    local sg = screen[1].geometry
    local path = os.tmpname()
    os.remove(path)
    path = path .. ".png"

    assert(ipc.dispatch("screenshot interactive " .. path, 4321) == nil,
        "dispatch should defer its response")
    assert(captured_ss, "no awful.screenshot instance was created")
    assert(mousegrabber.isrunning(), "mousegrabber should be active during snipping")

    local selected = nil
    captured_ss:connect_signal("property::selected_geometry", function(_, geo)
        selected = geo
    end)

    awful.spawn(string.format("%s drag 100 120 300 270 %d %d 1500",
        VPOINTER, sg.width, sg.height))

    -- The button is held for 1.5 s after the move: the dump must show the
    -- rectangle before the release ends the selection.
    local dump, line
    local drawn = async.wait_for_condition(function()
        dump = awesome._clay_tree(screen[1])
        line = dump:match("\n%s+%x+ wibox%.widget%.separator [^\n]*")
        return line and line:find("w=fixed(200) user h=fixed(150) user", 1, true)
            and line:find("box 100,120 200x150", 1, true)
    end, 1.2, 0.05)
    assert(drawn, "the selection rectangle is not 200x150 at 100,120: "
        .. tostring(line) .. "\n" .. dump)
    io.stderr:write("matched:" .. line .. "\n" .. dump .. "\n")

    for l in log_contents():gmatch("[^\n]+") do
        assert(not (l:find("left out of the tree", 1, true) and l:find("separator", 1, true)),
            "the separator was left out of the tree: " .. l)
    end

    assert(async.wait_for_condition(function() return captured_response ~= nil end, 5),
        "the release never finished the screenshot")
    assert(captured_response:match("^OK"), "expected OK, got: " .. captured_response)
    assert(selected and selected.x == 100 and selected.y == 120
        and selected.width == 200 and selected.height == 150,
        "selected_geometry is not 200x150 at 100,120")
    assert(not mousegrabber.isrunning(), "mousegrabber should have stopped")
    os.remove(path)

    io.stderr:write("[PASS] the drag draws the selection rectangle and saves its geometry\n")
    runner.done()
end)
