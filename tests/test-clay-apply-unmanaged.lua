---------------------------------------------------------------------------
--- Test: clay_apply_all skips an entry whose client was unmanaged between
--- end_layout and the deferred apply.
---
--- The apply walk in clay_apply_all dereferences r->client (border_width)
--- and calls client_resize. If a client is unmanaged in the window between
--- end_layout (sets has_pending) and the apply (Step 1.75 of some_refresh,
--- or the synchronous clay_c.apply_all() inside layout.solve), r->client
--- is a stale pointer. The fix gates the CLAY_ELEM_CLIENT arm on membership
--- in globalconf.clients (matches the input.c:1858 precedent).
---
--- A deterministic same-frame repro is not possible from Lua: c:kill() is
--- a Wayland close request, not a synchronous unmanage. So this is a stress
--- smoke test - spawn clients, force arranges, close them in rapid bursts,
--- assert the compositor stays up. Most valuable under ASAN, which catches
--- the use-after-free if a future code path widens the deferred-apply
--- window enough for the race to land.
---
--- Run: make test-one TEST=tests/test-clay-apply-unmanaged.lua
---      make test-asan TEST=tests/test-clay-apply-unmanaged.lua
---------------------------------------------------------------------------

local runner = require("_runner")
local async = require("_async")
local test_client = require("_client")
local awful = require("awful")

if not test_client.is_available() then
    io.stderr:write("SKIP: no terminal available\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local N = 3
local ROUNDS = 2

runner.run_async(function()
    local s = screen.primary
    local tag = s.tags[1]
    tag:view_only()
    tag.layout = awful.layout.suit.tile
    tag.gap = 0

    for round = 1, ROUNDS do
        io.stderr:write(string.format("[TEST] round %d/%d: spawn %d, arrange, kill\n",
            round, ROUNDS, N))

        for i = 1, N do
            test_client(string.format("apply_unmanaged_%d_%d", round, i))
        end

        local ok = async.wait_for_client_count(N, 5)
        assert(ok, string.format("round %d: expected %d clients", round, N))

        awful.layout.arrange(s)

        -- Close all clients in a tight burst. The unmanage runs whenever
        -- wlroots delivers the destroy/unmap; the next refresh after that
        -- exercises clay_apply_all on any pending entries that referenced
        -- the now-unmanaged client.
        for _, pid in ipairs(test_client.get_spawned_pids()) do
            os.execute("kill -9 " .. pid .. " 2>/dev/null")
        end

        ok = async.wait_for_no_clients(5)
        assert(ok, string.format("round %d: clients did not exit", round))

        awful.layout.arrange(s)
    end

    io.stderr:write("[ALL ROUNDS] PASS - compositor survived rapid spawn/kill cycles\n")
    runner.done()
end)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
