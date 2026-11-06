local runner = require("_runner")
local async = require("_async")
local awful = require("awful")

local function find_binary()
    for _, dir in ipairs({ "build-test", "build" }) do
        local path = "./" .. dir .. "/test-disconnect-mid-map-client"
        local file = io.open(path, "r")
        if file then
            file:close()
            return path
        end
    end
end

local binary = find_binary()
if not binary then
    return runner.skip("test-disconnect-mid-map-client not found (run make build-test)")
end

local function process_exists(pid)
    local file = io.open("/proc/" .. pid, "r")
    if file then
        file:close()
        return true
    end
    return false
end

-- What a helper that did not exit in time was doing, for the assertion.
local function process_state(pid)
    local out = {}
    for _, name in ipairs({ "status", "wchan" }) do
        local file = io.open("/proc/" .. pid .. "/" .. name, "r")
        if file then
            local text = file:read("*a") or ""
            file:close()
            local state = text:match("State:%s*([^\n]*)") or text
            out[#out + 1] = name .. "=" .. state
        end
    end
    return table.concat(out, " ")
end

-- Spawn the helper and resolve when the compositor has reaped it. The exit
-- callback is the compositor's own report; a /proc check cannot tell a
-- zombie from a running process.
local function spawn_and_wait_exit(args, timeout)
    local exited = false
    local pid = awful.spawn.with_line_callback(args, {
        exit = function() exited = true end,
    })
    assert(type(pid) == "number", tostring(pid))
    if not async.wait_for_condition(function() return exited end, timeout) then
        return pid, false, process_state(pid)
    end
    return pid, true
end

runner.run_async(function()
    local initial_count = #client.get()
    local managed = 0
    local pid
    local function on_manage()
        managed = managed + 1
    end
    client.connect_signal("request::manage", on_manage)

    local ok, err = xpcall(function()
        for i = 1, 5 do
            io.stderr:write("[TEST] before-map client " .. i .. "\n")
            local exited, state
            pid, exited, state = spawn_and_wait_exit({ binary, "--before-map" }, 15)
            assert(exited, "before-map client " .. i .. " did not exit: " .. tostring(state))
            pid = nil
        end

        assert(#client.get() == initial_count, "unmapped clients changed the client count")
        assert(managed == 0, "unmapped client emitted request::manage")
        assert(type(awesome.idle_inhibited) == "boolean", "idle_inhibited is unreadable")

        local control_exited = false
        pid = awful.spawn.with_line_callback({ binary }, {
            exit = function() control_exited = true end,
        })
        assert(type(pid) == "number", tostring(pid))
        assert(async.wait_for_condition(function()
            for _, c in ipairs(client.get()) do
                if c.class == "somewm.test.disconnect_mid_map" then
                    return true
                end
            end
            return control_exited
        end, 15), "control client neither appeared nor exited: " .. process_state(pid))
        assert(async.wait_for_condition(function()
            return #client.get() == initial_count and control_exited
        end, 15), "control client did not exit and return to the initial client count: " .. process_state(pid))
        pid = nil
    end, debug.traceback)

    client.disconnect_signal("request::manage", on_manage)
    if type(pid) == "number" and process_exists(pid) then
        awesome.kill(pid, 9)
    end
    assert(ok, err)
    runner.done()
end, { kill_clients = false })
