-- Regression for the hot-reload Phase F crash: when a transient appears
-- before its parent in client.get(), awesome.restart() must not crash
-- dereferencing the parent's not-yet-assigned screen. Compositor survival
-- is the pass signal (see test-hot-reload-basic.lua for the same pattern).

local runner = require("_runner")
local utils = require("_utils")
local awful = require("awful")

local function find_test_client_binary()
    local somewm = os.getenv("SOMEWM") or "./build-test/somewm"
    local build_dir = somewm:match("^(.*)/somewm$") or "./build-test"
    for _, candidate in ipairs({
        build_dir .. "/test-transient-client",
        "./build/test-transient-client",
        "./build-test/test-transient-client",
    }) do
        local f = io.open(candidate, "r")
        if f then f:close(); return candidate end
    end
    return nil
end

local TEST_TRANSIENT_CLIENT = find_test_client_binary()

if not TEST_TRANSIENT_CLIENT then
    io.stderr:write("SKIP: test-transient-client not found (run make build-test)\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local PARENT_CLASS = "transient_test_parent"
local parent_client
local child_client
local proc_pid

local steps = {
    function(count)
        if count == 1 then
            proc_pid = awful.spawn(TEST_TRANSIENT_CLIENT)
        end
        parent_client = utils.find_client_by_class(PARENT_CLASS)
        if parent_client then return true end
    end,

    function(count)
        if count == 1 then
            awesome.kill(proc_pid, 10) -- SIGUSR1
        end
        child_client = utils.find_clients(function(c)
            return c.transient_for == parent_client
        end)[1]
        if child_client then return true end
    end,

    function()
        local parent_idx, child_idx
        for i, c in ipairs(client.get()) do
            if c == parent_client then parent_idx = i end
            if c == child_client then child_idx = i end
        end
        assert(parent_idx and child_idx, "both clients must be in client.get()")
        assert(child_idx < parent_idx,
            "transient must come before parent for bug repro; got child="
            .. child_idx .. " parent=" .. parent_idx)
        assert(parent_client.screen, "parent must have a screen before reload")
        return true
    end,

    function(count)
        if count == 1 then
            awesome.restart()
        end
        return true
    end,
}

runner.run_steps(steps, { kill_clients = false })

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
