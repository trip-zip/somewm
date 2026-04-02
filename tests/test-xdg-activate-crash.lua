---------------------------------------------------------------------------
--- Test: XDG surface activate crash when closing client next to Xwayland
--
-- Regression test for trip-zip/somewm#386:
--   wlr_xdg_surface_schedule_configure: Assertion 'surface->initialized' failed
--
-- When a tiled XDG client (e.g. foot) is closed while bordering an Xwayland
-- client, the focus path deactivates the dying XDG surface via
-- client_activate_surface() before teardown completes. Without the initialized
-- guard, this triggers an assertion crash in wlroots.
--
-- Run with: make test-one TEST=tests/test-xdg-activate-crash.lua
---------------------------------------------------------------------------

local runner = require("_runner")
local test_client = require("_client")
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

	-- Spawn first client (simulates Xwayland client - any client will do
	-- since the crash is in the focus path when deactivating the SECOND client)
	local c1 = runner.spawn_and_wait()
	assert(c1, "Failed to spawn first client")
	io.stderr:write("  client 1: " .. tostring(c1.class) .. "\n")

	-- Spawn second client (the one we'll close - simulates foot)
	local c2 = runner.spawn_and_wait()
	assert(c2, "Failed to spawn second client")
	io.stderr:write("  client 2: " .. tostring(c2.class) .. "\n")

	-- Ensure both are tiled on same tag
	assert(#client.get() >= 2, "Expected at least 2 clients")

	-- Focus c2 then kill it - this triggers the focus transfer path
	-- that crashed before the fix (client_activate_surface on dying surface)
	client.focus = c2
	runner.wait(1)

	c2:kill()
	runner.wait(3)

	-- If we get here, the compositor didn't crash
	assert(#client.get() >= 1, "Expected at least 1 client after kill")
	io.stderr:write("  Compositor survived client kill - no crash!\n")

	-- Cleanup
	c1:kill()
	runner.wait(1)

	io.stderr:write("Test finished successfully.\n")
	return true
end)
