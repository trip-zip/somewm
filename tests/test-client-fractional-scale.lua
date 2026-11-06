-- Preferred surface scale stays at least 1, even on an output scaled below 1.
local awful = require("awful")
local runner = require("_runner")
local async = require("_async")

local function find_binary()
    local somewm = os.getenv("SOMEWM") or "./build-test/somewm"
    local build_dir = somewm:match("^(.*)/somewm$") or "./build-test"
    for _, candidate in ipairs({
        build_dir .. "/test-content-pattern-client",
        "./build/test-content-pattern-client",
        "./build-test/test-content-pattern-client",
    }) do
        local f = io.open(candidate, "r")
        if f then f:close(); return candidate end
    end
end

local BINARY = find_binary()
if not BINARY then
    return runner.skip("test-content-pattern-client not found (run `make build-test`)")
end

local function read_marker(pid, suffix)
    local f = io.open(string.format("/tmp/test-content-pattern-%d.%s", pid, suffix), "r")
    if not f then return nil end
    local last
    for line in f:lines() do last = line end
    f:close()
    return last
end

local pids = {}

local function run_case(scale, expected_fractional, expected_buffer)
    screen[1].scale = scale
    async.sleep(0.05)

    local pid = awful.spawn({BINARY})
    assert(type(pid) == "number" and pid > 0,
        "Failed to spawn binary: " .. tostring(pid))
    table.insert(pids, pid)

    local c = async.wait_for_client("content_pattern_test", 5)
    assert(c, "Client never appeared at scale=" .. scale)
    c.floating = true
    c:geometry { x = 173, y = 109, width = 200, height = 200 }
    assert(async.wait_for_condition(function()
        return tonumber(read_marker(pid, "scale")) == expected_buffer
    end, 5, 0.05), "Client never committed buffer scale=" .. expected_buffer)

    -- Initial configure can precede output enter, which updates preferred scale.
    local fractional
    async.wait_for_condition(function()
        local line = read_marker(pid, "fractional")
        fractional = line and tonumber(line:match("^fractional=(%d+)$"))
        return fractional == expected_fractional
    end, 5, 0.05)
    assert(fractional == expected_fractional, string.format(
        "scale=%s: expected fractional=%d, got %s",
        tostring(scale), expected_fractional, tostring(fractional)))

    assert(async.wait_for_condition(function()
        return c.valid and c._committed_size == nil
    end, 5, 0.05), "Client drew a size different from its configured size at scale=" .. scale)
    io.stderr:write(string.format(
        "[fractional-scale] scale=%s fractional=%d buffer=%d _committed_size=nil\n",
        tostring(scale), fractional, expected_buffer))

    c:kill()
    assert(async.wait_for_no_clients(3), "Client did not exit")
end

runner.run_async(function()
    local s = screen[1]
    local original_scale = s.scale
    local ok, err = pcall(function()
        run_case(0.8, 120, 1)
        run_case(2.0, 240, 2)
    end)

    s.scale = original_scale
    for _, pid in ipairs(pids) do
        os.execute("kill -9 " .. pid .. " 2>/dev/null")
        os.remove("/tmp/test-content-pattern-" .. pid .. ".scale")
        os.remove("/tmp/test-content-pattern-" .. pid .. ".fractional")
    end
    for _, c in ipairs(client.get()) do c:kill() end
    async.wait_for_no_clients(3)

    if not ok then
        runner.done("test-client-fractional-scale: " .. tostring(err))
    else
        runner.done()
    end
end)
