---------------------------------------------------------------------------
--- Test: XDG surface activate crash when closing client next to another
--
-- Regression test for trip-zip/somewm#386:
--   wlr_xdg_surface_schedule_configure: Assertion 'surface->initialized' failed
--
-- When a tiled XDG client (e.g. foot) is closed while bordering another
-- client, the focus path deactivates the dying XDG surface via
-- client_activate_surface() before teardown completes. Without the initialized
-- guard, this triggers an assertion crash in wlroots.
--
-- Run with: make test-one TEST=tests/test-xdg-activate-crash.lua
---------------------------------------------------------------------------

local runner = require("_runner")
local test_client = require("_client")
local async = require("_async")
local awful = require("awful")

if not test_client.is_available() then
	io.stderr:write("SKIP: no terminal available for client spawning\n")
	io.stderr:write("Test finished successfully.\n")
	awesome.quit()
	return
end

io.stderr:write("TEST: xdg-activate-crash (#386)\n")

runner.run_async(function()
	local s = screen.primary
	awful.layout.set(awful.layout.suit.tile, s.selected_tag)

	-- Spawn 2 clients (both XDG in test harness, but exercises the same
	-- focus transfer path that crashes with XDG+Xwayland mix)
	io.stderr:write("  Spawning 2 clients...\n")
	test_client("activate_crash_1", "Activate Test 1")
	test_client("activate_crash_2", "Activate Test 2")

	local ok = async.wait_for_client_count(2, 10)
	assert(ok, "Not all 2 clients appeared (got " .. #client.get() .. ")")
	io.stderr:write("  2 clients spawned\n")

	-- Focus second client then kill it — triggers focus transfer
	local clients = client.get()
	local c1 = clients[1]
	local c2 = clients[2]

	client.focus = c2
	async.sleep(0.5)
	io.stderr:write("  Focused: " .. tostring(c2.class) .. "\n")

	c2:kill()

	-- Wait for client to disappear
	local closed = async.wait_for_condition(function()
		return #client.get() <= 1
	end, 5)
	assert(closed, "Client did not close")

	-- If we get here, the compositor didn't crash
	io.stderr:write("  Compositor survived client kill — no crash!\n")
	assert(#client.get() >= 1, "Expected at least 1 client after kill")

	-- Cleanup
	for _, c in ipairs(client.get()) do
		c:kill()
	end
	async.wait_for_no_clients(5)

	io.stderr:write("Test finished successfully.\n")
	return true
end)
