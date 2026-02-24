---------------------------------------------------------------------------
--- Test: XDG surface crash guard during screen removal
--
-- Verifies that removing a screen with multiple XDG clients doesn't crash
-- the compositor. Regression test for the assertion:
--   wlr_xdg_surface_schedule_configure: Assertion 'surface->initialized' failed
--
-- Uses screen:fake_remove() which triggers the Lua-level screen removal
-- path (screen_removed → tag deletion → client migration). For the full
-- C-level crash path (closemon → setmon → resize → apply_geometry_to_wlroots),
-- use the live-session smoke-hotplug.sh with wlr-randr.
--
-- Run with: HEADLESS=1 WLR_WL_OUTPUTS=2 make test-one TEST=tests/test-xdg-hotplug-crash.lua
---------------------------------------------------------------------------

local runner = require("_runner")
local test_client = require("_client")
local async = require("_async")
local utils = require("_utils")
local awful = require("awful")

-- This test requires 2 outputs
if screen.count() < 2 then
	io.stderr:write("SKIP: test-xdg-hotplug-crash requires 2 outputs\n")
	io.stderr:write("Test finished successfully.\n")
	awesome.quit()
	return
end

-- Skip if no terminal for client spawning
if not test_client.is_available() then
	io.stderr:write("SKIP: no terminal available for client spawning\n")
	io.stderr:write("Test finished successfully.\n")
	awesome.quit()
	return
end

io.stderr:write("TEST: xdg-hotplug-crash: screen.count()=" .. screen.count() .. "\n")

runner.run_async(function()
	-----------------------------------------------------------------
	-- Step 1: Verify baseline — 2 screens with tags
	-----------------------------------------------------------------
	io.stderr:write("TEST: Step 1 - Verify 2 screens with tags\n")
	assert(screen.count() == 2, "Expected 2 screens, got " .. screen.count())
	for s in screen do
		assert(#s.tags > 0,
			"Screen " .. s.index .. " has no tags!")
		io.stderr:write("TEST:   screen " .. s.index .. ": " .. #s.tags .. " tags, "
			.. s.geometry.width .. "x" .. s.geometry.height .. "\n")
	end

	-----------------------------------------------------------------
	-- Step 2: Spawn 3 clients and move to screen 2
	-----------------------------------------------------------------
	io.stderr:write("TEST: Step 2 - Spawning 3 clients\n")

	for i = 1, 3 do
		test_client("xdg_crash_" .. i, "XDG Crash Test " .. i)
	end

	-- Wait for all 3 to appear
	local ok = async.wait_for_client_count(3, 10)
	assert(ok, "Not all 3 clients appeared (got " .. #client.get() .. ")")

	-- Move all clients to screen 2
	for _, c in ipairs(client.get()) do
		c:move_to_screen(screen[2])
	end
	async.sleep(0.3)

	local on_s2 = 0
	for _, c in ipairs(client.get()) do
		if c.screen and c.screen.index == 2 then
			on_s2 = on_s2 + 1
		end
	end
	io.stderr:write("TEST:   " .. on_s2 .. "/3 clients on screen 2\n")

	local clients_before = #client.get()
	io.stderr:write("TEST:   total clients: " .. clients_before .. "\n")

	-----------------------------------------------------------------
	-- Step 3: Remove screen 2 (triggers client migration path)
	-- screen:fake_remove() → screen_removed() → tag deletion →
	-- client migration to remaining screen
	-- Without proper guards, this can crash on configure.
	-----------------------------------------------------------------
	io.stderr:write("TEST: Step 3 - Removing screen 2 via fake_remove()\n")
	local s2 = screen[2]
	s2:fake_remove()
	async.sleep(0.5)

	io.stderr:write("TEST:   screen count now " .. screen.count() .. "\n")

	-----------------------------------------------------------------
	-- Step 4: Verify compositor survived and clients are alive
	-----------------------------------------------------------------
	io.stderr:write("TEST: Step 4 - Verify compositor survived\n")

	local clients_after = #client.get()
	io.stderr:write("TEST:   clients after remove: " .. clients_after .. "\n")
	assert(clients_after == clients_before,
		"Clients lost! Before=" .. clients_before .. " After=" .. clients_after)

	-- Check no orphaned clients (all should have a screen)
	local orphans = 0
	for _, c in ipairs(client.get()) do
		if not c.screen then
			orphans = orphans + 1
		end
	end
	assert(orphans == 0, orphans .. " orphaned clients without screen!")
	io.stderr:write("TEST:   no orphaned clients, all on screen 1\n")

	-----------------------------------------------------------------
	-- Step 5: Close a client while multiple visible (crash vector)
	-- @oeleonor reported crash specifically when closing a client
	-- with >1 client visible after hotplug cycle
	-----------------------------------------------------------------
	io.stderr:write("TEST: Step 5 - Close client with multiple visible\n")
	local first = utils.find_client_by_class("xdg_crash_1")
	if first and first.valid then
		first:kill()
		local closed = async.wait_for_condition(function()
			return utils.find_client_by_class("xdg_crash_1") == nil
		end, 5, 0.2)
		assert(closed, "Client did not close")
		io.stderr:write("TEST:   closed 1 client, " .. #client.get() .. " remaining\n")
	end

	-- Compositor still alive? If we got here, yes!
	io.stderr:write("TEST:   compositor alive after client close\n")

	-----------------------------------------------------------------
	-- Cleanup
	-----------------------------------------------------------------
	io.stderr:write("TEST: Cleanup - killing remaining clients\n")
	for _, c in ipairs(client.get()) do
		if c.valid then
			c:kill()
		end
	end
	async.wait_for_no_clients(5)

	io.stderr:write("TEST: PASS - xdg_surface crash guard works\n")
	runner.done()
end)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
