-- Test: screenshot.interactive IPC command defers its response, runs the
-- snipping mousegrabber, and replies via _ipc_send_response when the user
-- accepts or cancels.

local awful   = require("awful")
local ipc     = require("awful.ipc")
local runner  = require("_runner")

local awful_screenshot = require("awful.screenshot")

-- Wrap awful.screenshot so the test can grab the instance the handler
-- creates and drive it through reject() / save() to simulate user input.
local original_meta = getmetatable(awful_screenshot) or {}
local original_call = original_meta.__call
local captured_ss = nil
local new_meta = {}
for k, v in pairs(original_meta) do new_meta[k] = v end
new_meta.__call = function(cls, args)
    captured_ss = original_call(cls, args)
    return captured_ss
end
setmetatable(awful_screenshot, new_meta)

-- Stub _ipc_send_response so the test can read the deferred reply.
local captured_fd, captured_response = nil, nil
local original_send = _G._ipc_send_response
_G._ipc_send_response = function(fd, response)
    captured_fd, captured_response = fd, response
end

local function reset()
    captured_ss, captured_fd, captured_response = nil, nil, nil
end

local steps = {
    -- Cancel path: dispatch starts snipping, reject() sends ERROR reply.
    function()
        reset()

        local result = ipc.dispatch("screenshot interactive /tmp/test-interactive-cancel.png", 1234)
        assert(result == nil,
            "dispatch should return nil for deferred response, got: " .. tostring(result))
        assert(captured_ss, "no awful.screenshot instance was created")
        assert(mousegrabber.isrunning(), "mousegrabber should be active during snipping")
        assert(captured_response == nil, "response should not be sent yet")

        captured_ss:reject("test_cancel")

        assert(captured_fd == 1234, "wrong fd: " .. tostring(captured_fd))
        assert(captured_response, "no response sent on cancel")
        assert(captured_response:match("^ERROR"),
            "expected ERROR prefix, got: " .. tostring(captured_response))
        assert(captured_response:match("Screenshot cancelled"),
            "expected cancel message, got: " .. tostring(captured_response))
        assert(not mousegrabber.isrunning(), "mousegrabber should have stopped")

        return true
    end,

    -- Missing path arg: dispatch returns ERROR synchronously.
    function()
        reset()

        local result = ipc.dispatch("screenshot interactive", 1235)
        assert(type(result) == "string" and result:match("^ERROR"),
            "expected synchronous ERROR for missing path, got: " .. tostring(result))
        assert(captured_response == nil,
            "no async response should be sent on argument error")
        return true
    end,
}

-- Restore original _ipc_send_response when test exits (best-effort).
awesome.connect_signal("exit", function()
    _G._ipc_send_response = original_send
end)

runner.run_steps(steps)
